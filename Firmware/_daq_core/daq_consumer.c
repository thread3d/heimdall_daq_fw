/* daq_consumer.c -- attach to HeIMDALL's decimator_out and read IQ frames.
 *
 * This is the consumer HeIMDALL does not ship: a minimal client for the
 * decimator_out double buffer that prints the IQ frame header and per-channel
 * statistics, then hands each buffer back so the chain keeps running.
 *
 * It exists for two reasons:
 *   1. Without a consumer, the DAQ chain back-pressures: decimate.out fills
 *      decimator_out_A and _B and then stalls, which in turn stalls rebuffer
 *      and rtl_daq. "No data moving" is therefore not evidence of a fault.
 *   2. It is the seam that ogn-rf would eventually use in place of librtlsdr.
 *
 * Build (from Firmware/_daq_core, so the helper objects resolve):
 *   gcc -Wall -std=gnu99 -O2 -I. -o daq_consumer.out daq_consumer.c \
 *       sh_mem_util.o iq_header.o log.o ini.o -lrt
 *
 * Run (chain must already be up, and a fw/bw FIFO pair present):
 *   ./daq_consumer.out [frames]      default 10
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
 * with 4 bytes per component (complex float). Mirror that exactly, otherwise
 * the mmap length will not match the object the producer created. */
#define MAX_IQFRAME_PAYLOAD_SIZE (8388608u)

int main(int argc, char **argv)
{
    int want = (argc > 1) ? atoi(argv[1]) : 10;

    struct shmem_transfer_struct buf;
    memset(&buf, 0, sizeof(buf));
    strcpy(buf.shared_memory_names[0], DECIMATOR_OUT_SM_NAME_A);
    strcpy(buf.shared_memory_names[1], DECIMATOR_OUT_SM_NAME_B);
    strcpy(buf.fw_ctr_fifo_name, DECIMATOR_OUT_FW_FIFO);
    strcpy(buf.bw_ctr_fifo_name, DECIMATOR_OUT_BW_FIFO);
    buf.io_type = 1;   /* input */

    /* The channel count and therefore the buffer size come from the producer's
     * config; try 5 first and fall back if the object is a different length. */
    buf.shared_memory_size = MAX_IQFRAME_PAYLOAD_SIZE * 5 * 4 * 2 + IQ_HEADER_LENGTH;

    fprintf(stderr, "attaching to %s / %s\n",
            DECIMATOR_OUT_SM_NAME_A, DECIMATOR_OUT_SM_NAME_B);

    int ret = init_in_sm_buffer(&buf);
    if (ret != 0) {
        fprintf(stderr, "init_in_sm_buffer failed (%d). Is the DAQ chain running?\n", ret);
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

        printf("frame %2d: type=%u chs=%d cpi=%d depth=%dB dtype=%u fs=%.3f MHz fc=%.3f MHz "
               "block=%u cpi_idx=%u t=%llu\n",
               got, h->frame_type, chs, cpi, depth, h->data_type,
               srate / 1e6, (double)h->rf_center_freq / 1e6,
               h->daq_block_index, h->cpi_index,
               (unsigned long long)h->time_stamp);

        /* Dump the first payload words three ways, so the encoding is read off
         * the data rather than assumed. */
        {
            int nshow = 8;
            printf("            raw[0..%d] as bytes:", nshow - 1);
            for (int i = 0; i < nshow * 4; i++) printf(" %02x", payload[i]);
            printf("\n            as float32:");
            for (int i = 0; i < nshow; i++) printf(" %.6g", ((float *)payload)[i]);
            printf("\n            as int32  :");
            for (int i = 0; i < nshow; i++) printf(" %d", ((int32_t *)payload)[i]);
            printf("\n            as int16  :");
            for (int i = 0; i < nshow; i++) printf(" %d", ((int16_t *)payload)[i]);
            printf("\n");
        }

        /* Per-channel power. Payload is channel-major: cpi complex samples of
         * channel 0, then channel 1, and so on, each sample I then Q. */
        if (chs > 0 && cpi > 0 && bytes_per > 0 &&
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
                /* dBFS, not a raw magnitude: values are float32 but scaled to
                 * +-1/255 because they start life as 8-bit RTL samples, so a
                 * plain "%.1f" prints 0.0 and looks like dead data. */
                printf("ch%d=%.1fdBFS  ", c, dbfs);
            }
            printf("\n");
        }

        send_ctr_buff_free(&buf, idx);
        got++;
    }

    printf("\nread %d frame(s) from %s\n", got, DECIMATOR_OUT_SM_NAME_A);
    destory_sm_buffer(&buf);
    return got > 0 ? 0 : 1;
}
