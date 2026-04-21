/*
 * mpi_test_suite.c
 *
 * Self-contained MPI correctness and basic performance test suite.
 * Covers:
 *   [T01] Environment sanity  (rank/size, hostname)
 *   [T02] Point-to-point      (ping-pong latency, bandwidth)
 *   [T03] Barrier             (correctness + timing)
 *   [T04] Bcast               (correctness across sizes)
 *   [T05] Reduce / Allreduce  (correctness: sum, max)
 *   [T06] Alltoall            (correctness)
 *   [T07] Gather / Scatter    (correctness)
 *   [T08] Non-blocking        (Isend/Irecv + Waitall)
 *   [T09] Derived datatypes   (MPI_Type_vector)
 *   [T10] Communicator ops    (Comm_dup, Comm_split)
 *
 * Compile:
 *   mpicc -O2 -o mpi_test_suite mpi_test_suite.c -lm
 *
 * Run:
 *   mpirun -np <N> ./mpi_test_suite          # N >= 2
 *   mpirun -np <N> ./mpi_test_suite --verbose
 *   mpirun -np <N> ./mpi_test_suite --perf   # include latency/BW numbers
 */

#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdarg.h>
#include <unistd.h>

/* -------------------------------------------------------------------------
 * Configuration
 * ---------------------------------------------------------------------- */
#define WARMUP          200
#define LATENCY_ITERS   2000
#define BW_ITERS        200
#define BW_MSG_BYTES    (1 << 20)   /* 1 MB bandwidth test message */
#define MAX_COLL_BYTES  (1 << 22)   /* 4 MB max collective message */
#define EPSILON         1e-10

/* -------------------------------------------------------------------------
 * Globals
 * ---------------------------------------------------------------------- */
static int  g_rank   = 0;
static int  g_size   = 0;
static int  g_verbose = 0;
static int  g_perf   = 0;
static int  g_pass   = 0;
static int  g_fail   = 0;
static int  g_skip   = 0;

/* -------------------------------------------------------------------------
 * Helpers
 * ---------------------------------------------------------------------- */
#define ANSI_GREEN  "\033[1;32m"
#define ANSI_RED    "\033[1;31m"
#define ANSI_YELLOW "\033[1;33m"
#define ANSI_CYAN   "\033[1;36m"
#define ANSI_RESET  "\033[0m"

static void root_printf(const char *fmt, ...) {
    if (g_rank != 0) return;
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    fflush(stdout);
}

static void verbose_printf(const char *fmt, ...) {
    if (!g_verbose || g_rank != 0) return;
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    fflush(stdout);
}

static void test_pass(const char *name) {
    root_printf("  " ANSI_GREEN "[PASS]" ANSI_RESET " %s\n", name);
    g_pass++;
}

static void test_fail(const char *name, const char *reason) {
    root_printf("  " ANSI_RED "[FAIL]" ANSI_RESET " %s — %s\n", name, reason);
    g_fail++;
}

static void test_skip(const char *name, const char *reason) {
    root_printf("  " ANSI_YELLOW "[SKIP]" ANSI_RESET " %s — %s\n", name, reason);
    g_skip++;
}

static void section(const char *title) {
    root_printf("\n" ANSI_CYAN "--- %s ---" ANSI_RESET "\n", title);
}

/* Allreduce a local int status across all ranks; 0 = all OK */
static int global_status(int local_ok) {
    int global_ok;
    MPI_Allreduce(&local_ok, &global_ok, 1, MPI_INT, MPI_MIN, MPI_COMM_WORLD);
    return global_ok;
}

/* -------------------------------------------------------------------------
 * T01 — Environment sanity
 * ---------------------------------------------------------------------- */
static void test_environment(void) {
    section("T01: Environment");

    /* rank/size consistency */
    {
        int ok = (g_rank >= 0 && g_rank < g_size && g_size >= 2);
        ok = global_status(ok);
        if (ok) test_pass("rank/size sanity");
        else    test_fail("rank/size sanity", "invalid rank or size");
    }

    /* hostname reporting */
    {
        char hname[256] = {0};
        gethostname(hname, sizeof(hname));
        verbose_printf("    rank %d -> %s\n", g_rank, hname);
        /* just check it doesn't crash — always passes if we get here */
        int ok = global_status(1);
        if (ok) test_pass("hostname query");
        else    test_fail("hostname query", "unexpected");
    }

    /* MPI_Wtime resolution */
    {
        double res = MPI_Wtick();
        int ok = (res > 0.0 && res < 1.0);  /* sanity: better than 1s */
        ok = global_status(ok);
        if (ok) {
            verbose_printf("    MPI_Wtick = %.2e s\n", res);
            test_pass("MPI_Wtick resolution");
        } else {
            test_fail("MPI_Wtick resolution", "tick >= 1s or <= 0");
        }
    }
}

/* -------------------------------------------------------------------------
 * T02 — Point-to-point (ping-pong)
 * ---------------------------------------------------------------------- */
static void test_p2p(void) {
    section("T02: Point-to-point");

    if (g_size < 2) { test_skip("ping-pong", "need >= 2 ranks"); return; }

    /* --- correctness: send integer, verify value --- */
    {
        int val = 0, ok = 1;
        if (g_rank == 0) {
            val = 0xDEADBEEF;
            MPI_Send(&val, 1, MPI_INT, 1, 0, MPI_COMM_WORLD);
            MPI_Recv(&val, 1, MPI_INT, 1, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            ok = (val == 0xDEADBEEF) ? 1 : 0;
        } else if (g_rank == 1) {
            MPI_Recv(&val, 1, MPI_INT, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            MPI_Send(&val, 1, MPI_INT, 0, 0, MPI_COMM_WORLD);
        }
        ok = global_status(ok);
        if (ok) test_pass("ping-pong correctness (int)");
        else    test_fail("ping-pong correctness (int)", "value mismatch after round-trip");
    }

    /* --- correctness: send double array, verify sum --- */
    {
        int n = 1024;
        double *buf = (double *)malloc(n * sizeof(double));
        double expected_sum = 0.0, got_sum = 0.0;
        int ok = 1;
        if (g_rank == 0) {
            for (int i = 0; i < n; i++) { buf[i] = (double)i; expected_sum += buf[i]; }
            MPI_Send(buf, n, MPI_DOUBLE, 1, 1, MPI_COMM_WORLD);
            MPI_Recv(buf, n, MPI_DOUBLE, 1, 1, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            for (int i = 0; i < n; i++) got_sum += buf[i];
            ok = (fabs(got_sum - expected_sum) < EPSILON) ? 1 : 0;
        } else if (g_rank == 1) {
            MPI_Recv(buf, n, MPI_DOUBLE, 0, 1, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            MPI_Send(buf, n, MPI_DOUBLE, 0, 1, MPI_COMM_WORLD);
        }
        free(buf);
        ok = global_status(ok);
        if (ok) test_pass("ping-pong correctness (double array)");
        else    test_fail("ping-pong correctness (double array)", "sum mismatch");
    }

    /* --- status check: verify MPI_Status fields --- */
    {
        int sent = 42, recvd = 0, ok = 1;
        MPI_Status status;
        if (g_rank == 0) {
            MPI_Send(&sent, 1, MPI_INT, 1, 99, MPI_COMM_WORLD);
        } else if (g_rank == 1) {
            MPI_Recv(&recvd, 1, MPI_INT, 0, MPI_ANY_TAG, MPI_COMM_WORLD, &status);
            int count;
            MPI_Get_count(&status, MPI_INT, &count);
            ok = (status.MPI_SOURCE == 0 && status.MPI_TAG == 99
                  && count == 1 && recvd == 42) ? 1 : 0;
        }
        ok = global_status(ok);
        if (ok) test_pass("MPI_Status fields (source/tag/count)");
        else    test_fail("MPI_Status fields", "unexpected source/tag/count");
    }

    /* --- performance: latency and bandwidth --- */
    if (g_perf) {
        /* latency */
        {
            int msg = 0;
            for (int i = 0; i < WARMUP; i++) {
                if (g_rank == 0) {
                    MPI_Send(&msg, 1, MPI_INT, 1, 0, MPI_COMM_WORLD);
                    MPI_Recv(&msg, 1, MPI_INT, 1, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                } else if (g_rank == 1) {
                    MPI_Recv(&msg, 1, MPI_INT, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                    MPI_Send(&msg, 1, MPI_INT, 0, 0, MPI_COMM_WORLD);
                }
            }
            MPI_Barrier(MPI_COMM_WORLD);
            double t0 = MPI_Wtime();
            for (int i = 0; i < LATENCY_ITERS; i++) {
                if (g_rank == 0) {
                    MPI_Send(&msg, 1, MPI_INT, 1, 0, MPI_COMM_WORLD);
                    MPI_Recv(&msg, 1, MPI_INT, 1, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                } else if (g_rank == 1) {
                    MPI_Recv(&msg, 1, MPI_INT, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                    MPI_Send(&msg, 1, MPI_INT, 0, 0, MPI_COMM_WORLD);
                }
            }
            double t1 = MPI_Wtime();
            if (g_rank == 0) {
                double lat_us = ((t1 - t0) / (2.0 * LATENCY_ITERS)) * 1e6;
                root_printf("    latency (rank0<->rank1): %.3f us\n", lat_us);
            }
            test_pass("ping-pong latency measurement");
        }

        /* bandwidth */
        {
            char *sbuf = (char *)malloc(BW_MSG_BYTES);
            char *rbuf = (char *)malloc(BW_MSG_BYTES);
            memset(sbuf, 1, BW_MSG_BYTES);
            for (int i = 0; i < WARMUP/10; i++) {
                if (g_rank == 0) {
                    MPI_Send(sbuf, BW_MSG_BYTES, MPI_BYTE, 1, 0, MPI_COMM_WORLD);
                    MPI_Recv(rbuf, BW_MSG_BYTES, MPI_BYTE, 1, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                } else if (g_rank == 1) {
                    MPI_Recv(rbuf, BW_MSG_BYTES, MPI_BYTE, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                    MPI_Send(sbuf, BW_MSG_BYTES, MPI_BYTE, 0, 0, MPI_COMM_WORLD);
                }
            }
            MPI_Barrier(MPI_COMM_WORLD);
            double t0 = MPI_Wtime();
            for (int i = 0; i < BW_ITERS; i++) {
                if (g_rank == 0) {
                    MPI_Send(sbuf, BW_MSG_BYTES, MPI_BYTE, 1, 0, MPI_COMM_WORLD);
                    MPI_Recv(rbuf, BW_MSG_BYTES, MPI_BYTE, 1, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                } else if (g_rank == 1) {
                    MPI_Recv(rbuf, BW_MSG_BYTES, MPI_BYTE, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                    MPI_Send(sbuf, BW_MSG_BYTES, MPI_BYTE, 0, 0, MPI_COMM_WORLD);
                }
            }
            double t1 = MPI_Wtime();
            if (g_rank == 0) {
                /* bidirectional: 2 * bytes * iters / time */
                double bw_gbs = (2.0 * BW_MSG_BYTES * BW_ITERS) / (t1 - t0) / 1e9;
                root_printf("    bandwidth (rank0<->rank1, %d MB msg): %.2f GB/s\n",
                            BW_MSG_BYTES >> 20, bw_gbs);
            }
            free(sbuf); free(rbuf);
            test_pass("bandwidth measurement");
        }
    }
}

/* -------------------------------------------------------------------------
 * T03 — Barrier
 * ---------------------------------------------------------------------- */
static void test_barrier(void) {
    section("T03: Barrier");
    {
        /* All ranks set a flag before barrier, check after */
        int before = g_rank;  /* unique per rank */
        MPI_Barrier(MPI_COMM_WORLD);
        int after = g_rank;
        int ok = (before == after) ? 1 : 0;
        ok = global_status(ok);
        if (ok) test_pass("MPI_Barrier basic");
        else    test_fail("MPI_Barrier basic", "rank changed across barrier");
    }
    if (g_perf) {
        for (int i = 0; i < WARMUP; i++) MPI_Barrier(MPI_COMM_WORLD);
        MPI_Barrier(MPI_COMM_WORLD);
        double t0 = MPI_Wtime();
        for (int i = 0; i < LATENCY_ITERS; i++) MPI_Barrier(MPI_COMM_WORLD);
        double t1 = MPI_Wtime();
        root_printf("    barrier avg: %.3f us\n",
                    ((t1 - t0) / LATENCY_ITERS) * 1e6);
        test_pass("MPI_Barrier timing");
    }
}

/* -------------------------------------------------------------------------
 * T04 — Bcast
 * ---------------------------------------------------------------------- */
static void test_bcast(void) {
    section("T04: Bcast");

    int sizes[] = {1, 64, 4096, 65536, 1<<20, 0};
    for (int s = 0; sizes[s]; s++) {
        int n = sizes[s];
        char *buf = (char *)malloc(n);
        int ok = 1;

        if (g_rank == 0) memset(buf, 0xAB, n);
        else             memset(buf, 0x00, n);

        MPI_Bcast(buf, n, MPI_BYTE, 0, MPI_COMM_WORLD);

        for (int i = 0; i < n; i++) {
            if ((unsigned char)buf[i] != 0xAB) { ok = 0; break; }
        }
        free(buf);

        ok = global_status(ok);
        char label[64];
        snprintf(label, sizeof(label), "MPI_Bcast correctness (%d bytes)", n);
        if (ok) test_pass(label);
        else    test_fail(label, "data mismatch on non-root rank");
    }
}

/* -------------------------------------------------------------------------
 * T05 — Reduce / Allreduce
 * ---------------------------------------------------------------------- */
static void test_reduce(void) {
    section("T05: Reduce / Allreduce");

    /* Allreduce SUM of ranks: expected = size*(size-1)/2 */
    {
        long long local = g_rank, global = 0;
        long long expected = (long long)g_size * (g_size - 1) / 2;
        MPI_Allreduce(&local, &global, 1, MPI_LONG_LONG, MPI_SUM, MPI_COMM_WORLD);
        int ok = (global == expected) ? 1 : 0;
        ok = global_status(ok);
        if (ok) test_pass("MPI_Allreduce SUM (ranks)");
        else    test_fail("MPI_Allreduce SUM", "wrong sum");
    }

    /* Allreduce MAX */
    {
        int local = g_rank, global = 0;
        MPI_Allreduce(&local, &global, 1, MPI_INT, MPI_MAX, MPI_COMM_WORLD);
        int ok = (global == g_size - 1) ? 1 : 0;
        ok = global_status(ok);
        if (ok) test_pass("MPI_Allreduce MAX");
        else    test_fail("MPI_Allreduce MAX", "wrong max");
    }

    /* Reduce to root, only root checks */
    {
        double local = 1.0, sum = 0.0;
        double expected = (double)g_size;
        MPI_Reduce(&local, &sum, 1, MPI_DOUBLE, MPI_SUM, 0, MPI_COMM_WORLD);
        int ok = 1;
        if (g_rank == 0) ok = (fabs(sum - expected) < EPSILON) ? 1 : 0;
        ok = global_status(ok);
        if (ok) test_pass("MPI_Reduce SUM to root");
        else    test_fail("MPI_Reduce SUM", "wrong sum on root");
    }

    /* Large Allreduce — stress UCC/hcoll path */
    {
        int n = MAX_COLL_BYTES / sizeof(double);
        double *sbuf = (double *)malloc(n * sizeof(double));
        double *rbuf = (double *)malloc(n * sizeof(double));
        for (int i = 0; i < n; i++) sbuf[i] = 1.0;
        MPI_Allreduce(sbuf, rbuf, n, MPI_DOUBLE, MPI_SUM, MPI_COMM_WORLD);
        int ok = 1;
        double expected = (double)g_size;
        for (int i = 0; i < n; i++) {
            if (fabs(rbuf[i] - expected) > EPSILON) { ok = 0; break; }
        }
        free(sbuf); free(rbuf);
        ok = global_status(ok);
        char label[64];
        snprintf(label, sizeof(label), "MPI_Allreduce large (%d MB)",
                 (int)(n * sizeof(double) >> 20));
        if (ok) test_pass(label);
        else    test_fail(label, "value mismatch in result buffer");
    }
}

/* -------------------------------------------------------------------------
 * T06 — Alltoall
 * ---------------------------------------------------------------------- */
static void test_alltoall(void) {
    section("T06: Alltoall");

    /* Each rank sends its rank value to all, verifies it received 0..size-1 */
    {
        int *sbuf = (int *)malloc(g_size * sizeof(int));
        int *rbuf = (int *)malloc(g_size * sizeof(int));
        for (int i = 0; i < g_size; i++) sbuf[i] = g_rank;
        MPI_Alltoall(sbuf, 1, MPI_INT, rbuf, 1, MPI_INT, MPI_COMM_WORLD);
        int ok = 1;
        for (int i = 0; i < g_size; i++) {
            if (rbuf[i] != i) { ok = 0; break; }
        }
        free(sbuf); free(rbuf);
        ok = global_status(ok);
        if (ok) test_pass("MPI_Alltoall correctness");
        else    test_fail("MPI_Alltoall correctness", "wrong rank values received");
    }
}

/* -------------------------------------------------------------------------
 * T07 — Gather / Scatter
 * ---------------------------------------------------------------------- */
static void test_gather_scatter(void) {
    section("T07: Gather / Scatter");

    /* Gather: root collects rank from each rank */
    {
        int send = g_rank;
        int *recv = NULL;
        if (g_rank == 0) recv = (int *)malloc(g_size * sizeof(int));
        MPI_Gather(&send, 1, MPI_INT, recv, 1, MPI_INT, 0, MPI_COMM_WORLD);
        int ok = 1;
        if (g_rank == 0) {
            for (int i = 0; i < g_size; i++)
                if (recv[i] != i) { ok = 0; break; }
            free(recv);
        }
        ok = global_status(ok);
        if (ok) test_pass("MPI_Gather correctness");
        else    test_fail("MPI_Gather correctness", "wrong values at root");
    }

    /* Scatter: root sends i to rank i, each rank verifies */
    {
        int *send = NULL;
        int recv = -1;
        if (g_rank == 0) {
            send = (int *)malloc(g_size * sizeof(int));
            for (int i = 0; i < g_size; i++) send[i] = i * 10;
        }
        MPI_Scatter(send, 1, MPI_INT, &recv, 1, MPI_INT, 0, MPI_COMM_WORLD);
        if (g_rank == 0) free(send);
        int ok = (recv == g_rank * 10) ? 1 : 0;
        ok = global_status(ok);
        if (ok) test_pass("MPI_Scatter correctness");
        else    test_fail("MPI_Scatter correctness", "wrong value received");
    }

    /* Allgather */
    {
        int send = g_rank;
        int *recv = (int *)malloc(g_size * sizeof(int));
        MPI_Allgather(&send, 1, MPI_INT, recv, 1, MPI_INT, MPI_COMM_WORLD);
        int ok = 1;
        for (int i = 0; i < g_size; i++)
            if (recv[i] != i) { ok = 0; break; }
        free(recv);
        ok = global_status(ok);
        if (ok) test_pass("MPI_Allgather correctness");
        else    test_fail("MPI_Allgather correctness", "wrong values");
    }
}

/* -------------------------------------------------------------------------
 * T08 — Non-blocking (Isend/Irecv)
 * ---------------------------------------------------------------------- */
static void test_nonblocking(void) {
    section("T08: Non-blocking");

    /* Ring: each rank sends to (rank+1)%size, receives from (rank-1+size)%size */
    {
        int send_val = g_rank;
        int recv_val = -1;
        int dst = (g_rank + 1) % g_size;
        int src = (g_rank - 1 + g_size) % g_size;
        MPI_Request reqs[2];
        MPI_Irecv(&recv_val, 1, MPI_INT, src, 10, MPI_COMM_WORLD, &reqs[0]);
        MPI_Isend(&send_val, 1, MPI_INT, dst, 10, MPI_COMM_WORLD, &reqs[1]);
        MPI_Waitall(2, reqs, MPI_STATUSES_IGNORE);
        int ok = (recv_val == src) ? 1 : 0;
        ok = global_status(ok);
        if (ok) test_pass("Isend/Irecv ring (Waitall)");
        else    test_fail("Isend/Irecv ring", "wrong value received");
    }

    /* Multiple simultaneous requests */
    {
        int ntags = 4;
        int *sbuf = (int *)malloc(ntags * sizeof(int));
        int *rbuf = (int *)calloc(ntags, sizeof(int));
        MPI_Request *reqs = (MPI_Request *)malloc(2 * ntags * sizeof(MPI_Request));
        int dst = (g_rank + 1) % g_size;
        int src = (g_rank - 1 + g_size) % g_size;
        for (int t = 0; t < ntags; t++) sbuf[t] = g_rank * 100 + t;
        for (int t = 0; t < ntags; t++) {
            MPI_Irecv(&rbuf[t], 1, MPI_INT, src, t, MPI_COMM_WORLD, &reqs[t]);
            MPI_Isend(&sbuf[t], 1, MPI_INT, dst, t, MPI_COMM_WORLD, &reqs[ntags+t]);
        }
        MPI_Waitall(2 * ntags, reqs, MPI_STATUSES_IGNORE);
        int ok = 1;
        for (int t = 0; t < ntags; t++) {
            int expected = src * 100 + t;
            if (rbuf[t] != expected) { ok = 0; break; }
        }
        free(sbuf); free(rbuf); free(reqs);
        ok = global_status(ok);
        if (ok) test_pass("Isend/Irecv multiple tags");
        else    test_fail("Isend/Irecv multiple tags", "wrong value on one or more tags");
    }
}

/* -------------------------------------------------------------------------
 * T09 — Derived datatypes
 * ---------------------------------------------------------------------- */
static void test_datatypes(void) {
    section("T09: Derived datatypes");

    if (g_size < 2) { test_skip("MPI_Type_vector", "need >= 2 ranks"); return; }

    /* MPI_Type_vector: send every other element of an array */
    {
        int n = 16;
        int stride = 2;
        int count = n / stride;   /* 8 elements */
        MPI_Datatype vec_type;
        MPI_Type_vector(count, 1, stride, MPI_INT, &vec_type);
        MPI_Type_commit(&vec_type);

        int *sbuf = (int *)malloc(n * sizeof(int));
        int *rbuf = (int *)calloc(count, sizeof(int));

        if (g_rank == 0) {
            for (int i = 0; i < n; i++) sbuf[i] = i;
            MPI_Send(sbuf, 1, vec_type, 1, 20, MPI_COMM_WORLD);
        } else if (g_rank == 1) {
            MPI_Recv(rbuf, count, MPI_INT, 0, 20, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        }

        int ok = 1;
        if (g_rank == 1) {
            /* Should have received: 0, 2, 4, 6, 8, 10, 12, 14 */
            for (int i = 0; i < count; i++) {
                if (rbuf[i] != i * stride) { ok = 0; break; }
            }
        }

        MPI_Type_free(&vec_type);
        free(sbuf); free(rbuf);
        ok = global_status(ok);
        if (ok) test_pass("MPI_Type_vector (strided send)");
        else    test_fail("MPI_Type_vector", "wrong element values received");
    }

    /* MPI_Type_contiguous */
    {
        MPI_Datatype contig;
        MPI_Type_contiguous(4, MPI_DOUBLE, &contig);
        MPI_Type_commit(&contig);
        double sbuf[4] = {1.1, 2.2, 3.3, 4.4};
        double rbuf[4] = {0};
        if (g_rank == 0) MPI_Send(sbuf, 1, contig, 1, 21, MPI_COMM_WORLD);
        else if (g_rank == 1) MPI_Recv(rbuf, 1, contig, 0, 21, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        int ok = 1;
        if (g_rank == 1) {
            for (int i = 0; i < 4; i++)
                if (fabs(rbuf[i] - sbuf[i]) > EPSILON) { ok = 0; break; }
        }
        MPI_Type_free(&contig);
        ok = global_status(ok);
        if (ok) test_pass("MPI_Type_contiguous");
        else    test_fail("MPI_Type_contiguous", "value mismatch");
    }
}

/* -------------------------------------------------------------------------
 * T10 — Communicator operations
 * ---------------------------------------------------------------------- */
static void test_communicators(void) {
    section("T10: Communicators");

    /* Comm_dup */
    {
        MPI_Comm dup;
        MPI_Comm_dup(MPI_COMM_WORLD, &dup);
        int dup_rank, dup_size;
        MPI_Comm_rank(dup, &dup_rank);
        MPI_Comm_size(dup, &dup_size);
        int ok = (dup_rank == g_rank && dup_size == g_size) ? 1 : 0;
        /* ping-pong on the dup communicator */
        int val = 0;
        if (g_rank == 0) {
            val = 777;
            MPI_Send(&val, 1, MPI_INT, 1, 0, dup);
            MPI_Recv(&val, 1, MPI_INT, 1, 0, dup, MPI_STATUS_IGNORE);
            ok &= (val == 777);
        } else if (g_rank == 1) {
            MPI_Recv(&val, 1, MPI_INT, 0, 0, dup, MPI_STATUS_IGNORE);
            MPI_Send(&val, 1, MPI_INT, 0, 0, dup);
        }
        MPI_Comm_free(&dup);
        ok = global_status(ok);
        if (ok) test_pass("MPI_Comm_dup + p2p on dup");
        else    test_fail("MPI_Comm_dup", "rank/size mismatch or p2p failed");
    }

    /* Comm_split: split into even/odd ranks */
    {
        int color = g_rank % 2;
        MPI_Comm split;
        MPI_Comm_split(MPI_COMM_WORLD, color, g_rank, &split);
        int split_rank, split_size;
        MPI_Comm_rank(split, &split_rank);
        MPI_Comm_size(split, &split_size);
        /* Allreduce within the split comm */
        int local = 1, total = 0;
        MPI_Allreduce(&local, &total, 1, MPI_INT, MPI_SUM, split);
        int expected_size = (color == 0)
            ? (g_size + 1) / 2   /* even ranks */
            : g_size / 2;        /* odd ranks  */
        int ok = (total == expected_size && split_size == expected_size) ? 1 : 0;
        MPI_Comm_free(&split);
        ok = global_status(ok);
        if (ok) test_pass("MPI_Comm_split (even/odd) + Allreduce");
        else    test_fail("MPI_Comm_split", "wrong size or allreduce result");
    }
}

/* -------------------------------------------------------------------------
 * Main
 * ---------------------------------------------------------------------- */
int main(int argc, char *argv[]) {
    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &g_rank);
    MPI_Comm_size(MPI_COMM_WORLD, &g_size);

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--verbose") == 0 || strcmp(argv[i], "-v") == 0)
            g_verbose = 1;
        if (strcmp(argv[i], "--perf") == 0 || strcmp(argv[i], "-p") == 0)
            g_perf = 1;
    }

    root_printf("\n");
    root_printf(ANSI_CYAN "========================================\n" ANSI_RESET);
    root_printf(ANSI_CYAN "  MPI Test Suite\n" ANSI_RESET);
    root_printf(ANSI_CYAN "========================================\n" ANSI_RESET);
    root_printf("  Ranks   : %d\n", g_size);
    root_printf("  Verbose : %s\n", g_verbose ? "yes" : "no");
    root_printf("  Perf    : %s\n", g_perf    ? "yes" : "no");

    if (g_size < 2) {
        root_printf("\nERROR: This test suite requires at least 2 MPI ranks.\n");
        MPI_Finalize();
        return 1;
    }

    test_environment();
    test_p2p();
    test_barrier();
    test_bcast();
    test_reduce();
    test_alltoall();
    test_gather_scatter();
    test_nonblocking();
    test_datatypes();
    test_communicators();

    /* ---- Summary ---- */
    root_printf("\n");
    root_printf(ANSI_CYAN "========================================\n" ANSI_RESET);
    root_printf("  Results: " ANSI_GREEN "%d passed" ANSI_RESET
                ", " ANSI_RED "%d failed" ANSI_RESET
                ", " ANSI_YELLOW "%d skipped" ANSI_RESET "\n",
                g_pass, g_fail, g_skip);
    root_printf(ANSI_CYAN "========================================\n" ANSI_RESET);
    root_printf("\n");

    int exit_code = (g_fail > 0) ? 1 : 0;
    MPI_Finalize();
    return exit_code;
}
