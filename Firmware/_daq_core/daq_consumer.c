/* daq_consumer.c -- read IQ frames from a HeIMDALL shared-memory stage.
 *
 * HeIMDALL ships no consumer: delay_sync.py normally reads decimator_out, and
 * the DoA application reads whatever delay_sync produces. Without a consumer the
 * chain back-pressures (decimate fills decimator_out_A/_B then stalls, stalling
 * rebuffer and rtl_daq), so "no data is moving" proves nothing until something
 * reads the far end. This is that something, for measurement.
 *
 *   ./daq_consumer.out [frames] [decimator_out|delay_sync_iq]
 *
 * Stage choice matters: decimator_out is correct while nothing else consumes it,
 * but once delay_sync.py runs it OWNS decimator_out. Reading the same stage from
 * two consumers makes them steal each other's buffers and both stall, so a
 * coherent run must read delay_sync_iq instead.
 *
 * Build (from Firmware/_daq_core, so the helper objects resolve):
 *   gcc -Wall -std=gnu99 -O2 -I. -o daq_consumer.out daq_consumer.c \
 *       sh_mem_util.o iq_header.o log.o ini.o -lrt -lm
 *
 * Licence: GPL v3 (HeIMDALL is GPL v3).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <unistd.h>

#include "iq_header.h"
#include "sh_mem_util.h"

/* fir_decimate.c sizes its output as
 *   MAX_IQFRAME_PAYLOAD_SIZE * ch_no * 4 * 2 + IQ_HEADER_LENGTH
 * with 4 bytes per component (complex float). Mirror it exactly or the mmap
 * length will not match the object the producer created. */
#define MAX_IQFRAME_PAYLOAD_SIZE (8388608u)
#define MAX_CH 8
#define RAW_DUMP_FRAMES 2

static void select_stage(struct shmem_transfer_struct *buf, const char *stage)
{
    if (strcmp(stage, "decimator_out") == 0) {
        strcpy(buf->shared_memory_names[0], DECIMATOR_OUT_SM_NAME_A);
        strcpy(buf->shared_memory_names[1], DECIMATOR_OUT_SM_NAME_B);
        strcpy(buf->fw_ctr_fifo_name, DECIMATOR_OUT_FW_FIFO);
        strcpy(buf->bw_ctr_fifo_name, DECIMATOR_OUT_BW_FIFO);
    } else if (strcmp(stage, "delay_sync_iq") == 0) {
        strcpy(buf->shared_memory_names[0], DELAY_SYNC_IQ_SM_NAME_A);
        strcpy(buf->shared_memory_names[1], DELAY_SYNC_IQ_SM_NAME_B);
        strcpy(buf->fw_ctr_fifo_name, DELAY_SYNC_IQ_FW_FIFO);
        strcpy(buf->bw_ctr_fifo_name, DELAY_SYNC_IQ_BW_FIFO);
    } else {
        fprintf(stderr, "unknown stage '%s' (use decimator_out or delay_sync_iq)\n",
                stage);
        exit(2);
    }
}

int main(int argc, char **argv)
{
    int want = (argc > 1) ? atoi(argv[1]) : 10;
    const char *stage = (argc > 2) ? argv[2] : "decimator_out";

    struct shmem_transfer_struct buf;
    memset(&buf, 0, sizeof(buf));
    buf.io_type = 1;   /* input */

    select_stage(&buf, stage);

    /* Channel count comes from the producer's config, so the buffer size is
     * assumed for the maximum and validated against the header once attached
     * only as far as bounds-checking goes. */
    buf.shared_memory_size = MAX_IQFRAME_PAYLOAD_SIZE * MAX_CH * 4 * 2 +
                             IQ_HEADER_LENGTH;

    fprintf(stderr, "attaching to %s / %s\n",
            buf.shared_memory_names[0], buf.shared_memory_names[1]);

    int ret = init_in_sm_buffer(&buf);
    if (ret != 0) {
        fprintf(stderr, "init_in_sm_buffer failed (%d). Producer for '%s' "
                        "not ready.\n", ret, stage);
        return 2;
    }
    fprintf(stderr, "attached\n");

    int got = 0;
    while (got < want) {
        int idx = wait_buff_ready(&buf);
        if (idx == TERMINATE) { fprintf(stderr, "producer sent TERMINATE\n"); break; }
        if (idx < 0) { fprintf(stderr, "wait_buff_ready failed (%d)\n", idx); break; }

        struct iq_header_struct *h = (struct iq_header_struct *)buf.shm_ptr[idx];
        if (h->sync_word != SYNC_WORD) {
            fprintf(stderr, "frame %d: bad sync word 0x%08x (expected 0x%08x)\n",
                    got, h->sync_word, SYNC_WORD);
            send_ctr_buff_free(&buf, idx);
            got++;
            continue;
        }

        uint8_t *payload = (uint8_t *)buf.shm_ptr[idx] + IQ_HEADER_LENGTH;
        int chs   = (int)h->active_ant_chs;
        int cpi   = (int)h->cpi_length;
        int depth = (int)h->sample_bit_depth;
        int bytes_per = (depth + 7) / 8;
        double srate = (double)h->sampling_freq;

        printf("frame %2d: type=%u chs=%d cpi=%d depth=%dB dtype=%u fs=%.3f MHz "
               "fc=%.3f MHz block=%u cpi_idx=%u t=%llu\n",
               got, h->frame_type, chs, cpi, depth, h->data_type,
               srate / 1e6, (double)h->rf_center_freq / 1e6,
               h->daq_block_index, h->cpi_index,
               (unsigned long long)h->time_stamp);

        /* On the first frames, show the raw payload three ways so the encoding
         * is read off the data instead of assumed. Samples are float32 but
         * scaled to +-1/255 because they begin life as 8-bit RTL samples, which
         * is why a plain "%.1f" on the magnitude prints 0.0 and looks like dead
         * data. Everything below is reported in dBFS for that reason. */
        if (got < RAW_DUMP_FRAMES) {
            printf("            raw[0..7] as bytes  :");
            for (int i = 0; i < 32; i++) printf(" %02x", payload[i]);
            printf("\n            as float32          :");
            for (int i = 0; i < 8; i++) printf(" %.6g", ((float *)payload)[i]);
            printf("\n");
        }

        if (chs > 0 && chs <= MAX_CH && cpi > 0 && bytes_per > 0 &&
            (long)IQ_HEADER_LENGTH + (long)chs * cpi * 2 * bytes_per
                <= (long)buf.shared_memory_size) {
            printf("            ");
            for (int c = 0; c < chs; c++) {
                double sum = 0;
                long n = 0;
                uint8_t *base = payload + (long)c * cpi * 2 * bytes_per;
                for (int i = 0; i < cpi * 2; i++) {
                    double v;
                    if (depth == 8)       v = (double)((int8_t *)base)[i];
                    else if (depth == 16) v = (double)((int16_t *)base)[i];
                    else                  v = (double)((float *)base)[i];
                    sum += v * v; n++;
                }
                double rms = n ? sqrt(sum / n) : 0;
                double dbfs = (rms > 0) ? 20.0 * log10(rms) : -999.0;
                printf("ch%d=%.1fdBFS  ", c, dbfs);
            }
            printf("\n");
        }

        send_ctr_buff_free(&buf, idx);
        got++;
    }

    printf("\nread %d frame(s) from %s\n", got, buf.shared_memory_names[0]);
    destory_sm_buffer(&buf);
    return got > 0 ? 0 : 1;
}
