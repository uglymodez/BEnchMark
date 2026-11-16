#define _POSIX_C_SOURCE 200809L
#include "benchmark.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <errno.h>
#include <math.h>
#include <time.h>

static volatile sig_atomic_t interrupted;
static void stop(int sig) { interrupted=sig; }
static void usage(const char *name) {
    fprintf(stderr,"Usage: %s [--mode read|write|execute|latency|all] [--max-mib 1..1024]\n"
        "  [--profile quick|standard|precise] [--quick] [--samples 1..9]\n"
        "  [--seconds 0.001..1] [--format csv|json] [--descending]\n",name);
}
static int integer(const char *text, long low, long high, long *out) {
    char *end; errno=0; long n=strtol(text,&end,10);
    if (errno || end==text || *end || n<low || n>high) return 0;
    *out=n; return 1;
}
int main(int argc, char **argv) {
    size_t maximum=64*1024*1024; double seconds=0.035, override_seconds=0;
    unsigned samples=5, override_samples=0; int selected=-1, json=0, descending=0;
    const char *profile="standard";
    for (int i=1; i<argc; ++i) {
        if (!strcmp(argv[i],"--help")) { usage(argv[0]); return 0; }
        if (!strcmp(argv[i],"--descending")) { descending=1; continue; }
        if (!strcmp(argv[i],"--quick")) { profile="quick"; continue; }
        if (i+1>=argc) { usage(argv[0]); return 2; }
        const char *option=argv[i], *value=argv[++i]; long number;
        if (!strcmp(option,"--mode")) {
            if (!strcmp(value,"all")) selected=-1;
            else if (!strcmp(value,"read")) selected=MB_READ;
            else if (!strcmp(value,"write")) selected=MB_WRITE;
            else if (!strcmp(value,"execute")) selected=MB_EXECUTE;
            else if (!strcmp(value,"latency")) selected=MB_LATENCY;
            else { usage(argv[0]); return 2; }
        } else if (!strcmp(option,"--max-mib")) {
            if (!integer(value,1,1024,&number)) { usage(argv[0]); return 2; }
            maximum=(size_t)number*1024*1024;
        } else if (!strcmp(option,"--samples")) {
            if (!integer(value,1,MB_MAX_SAMPLES,&number)) { usage(argv[0]); return 2; }
            override_samples=(unsigned)number;
        } else if (!strcmp(option,"--seconds")) {
            char *end; errno=0; override_seconds=strtod(value,&end);
            if (errno || *end || end==value || !isfinite(override_seconds) || override_seconds<0.001 || override_seconds>1) {
                usage(argv[0]); return 2;
            }
        } else if (!strcmp(option,"--profile")) {
            if (strcmp(value,"quick") && strcmp(value,"standard") && strcmp(value,"precise")) { usage(argv[0]); return 2; }
            profile=value;
        } else if (!strcmp(option,"--format")) {
            if (strcmp(value,"csv") && strcmp(value,"json")) { usage(argv[0]); return 2; }
            json=!strcmp(value,"json");
        } else { usage(argv[0]); return 2; }
    }
    if (!strcmp(profile,"quick")) { seconds=0.015; samples=3; }
    if (!strcmp(profile,"precise")) { seconds=0.060; samples=9; }
    if (override_seconds) seconds=override_seconds;
    if (override_samples) samples=override_samples;
    signal(SIGINT,stop); signal(SIGTERM,stop);
    mb_context *ctx=mb_create(); if (!ctx) return 1;
    mb_set_cancel_flag(ctx,&interrupted);
    time_t epoch=time(NULL); char started[32]="unknown"; struct tm utc;
    if (gmtime_r(&epoch,&utc)) strftime(started,sizeof(started),"%Y-%m-%dT%H:%M:%SZ",&utc);
    fprintf(stderr,"%s; %s; one thread; samples=%u; seconds/sample=%.3f\n",mb_method_version(),mb_architecture(),samples,seconds);
    if (json) {
        printf("{\"schema_version\":2,\"method\":\"%s\",\"architecture\":\"%s\",\"started\":\"%s\","
               "\"profile\":\"%s\",\"samples\":%u,\"seconds_per_sample\":%.6f,\"maximum_bytes\":%zu,"
               "\"threads\":1,\"order\":\"%s\",\"latency_stride_bytes\":%d,\"points\":[\n",
               mb_method_version(),mb_architecture(),started,profile,samples,seconds,maximum,
               descending?"descending":"ascending",MB_LATENCY_STRIDE);
    } else {
        printf("# schema_version: 2\n# method: %s\n# architecture: %s\n# started: %s\n# profile: %s\n"
               "# seconds_per_sample: %.6f\n# samples: %u\n# maximum_bytes: %zu\n# threads: 1\n"
               "# order: %s\n# latency_stride_bytes: %d\n",
               mb_method_version(),mb_architecture(),started,profile,seconds,samples,maximum,
               descending?"descending":"ascending",MB_LATENCY_STRIDE);
        puts("operation,buffer_bytes,unit,median,minimum,maximum,cv_percent,total_sample_seconds,iterations,samples,sample_1,sample_2,sample_3,sample_4,sample_5,sample_6,sample_7,sample_8,sample_9");
    }
    size_t sizes[80], count=mb_sizes(maximum,sizes,80); int exit_code=0, emitted=0, unavailable=0;
    for (size_t i=0; i<count && !interrupted; ++i) {
        size_t n=sizes[descending?count-1-i:i];
        for (int op=MB_READ; op<=MB_LATENCY && !interrupted; ++op) {
            if (selected>=0 && op!=selected) continue;
            if (op==MB_EXECUTE && (unavailable || n>64*1024*1024)) continue;
            mb_result r; mb_status status=mb_measure(ctx,(mb_operation)op,n,seconds,samples,&r);
            if (status==MB_UNAVAILABLE && op==MB_EXECUTE) {
                fprintf(stderr,"execute unavailable: %s\n",mb_error(ctx)); unavailable=1;
                if (selected==MB_EXECUTE) exit_code=1;
                continue;
            }
            if (status==MB_CANCELLED) goto done;
            if (status!=MB_OK) { fprintf(stderr,"%s\n",mb_error(ctx)); exit_code=1; goto done; }
            if (json) {
                printf("%s{\"operation\":\"%s\",\"buffer_bytes\":%zu,\"unit\":\"%s\",\"median\":%.9f,"
                       "\"minimum\":%.9f,\"maximum\":%.9f,\"cv_percent\":%.6f,\"total_sample_seconds\":%.9f,"
                       "\"iterations\":%llu,\"samples\":%u,\"sample_values\":[",
                       emitted?",\n":"",mb_operation_name(r.operation),r.bytes,mb_operation_unit(r.operation),
                       mb_result_value(&r),mb_result_minimum(&r),mb_result_maximum(&r),r.cv_percent,
                       r.seconds,(unsigned long long)r.passes,r.samples);
                for (unsigned k=0;k<r.samples;++k) printf("%s%.9f",k?",":"",r.sample_values[k]);
                printf("]}");
            } else {
                printf("%s,%zu,%s,%.9f,%.9f,%.9f,%.6f,%.9f,%llu,%u",
                       mb_operation_name(r.operation),r.bytes,mb_operation_unit(r.operation),
                       mb_result_value(&r),mb_result_minimum(&r),mb_result_maximum(&r),r.cv_percent,
                       r.seconds,(unsigned long long)r.passes,r.samples);
                for (unsigned k=0;k<MB_MAX_SAMPLES;++k) {
                    if (k<r.samples) printf(",%.9f",r.sample_values[k]); else putchar(',');
                }
                putchar('\n');
            }
            emitted=1; fflush(stdout);
        }
    }
done:
    if (interrupted) exit_code=128+interrupted;
    const char *state=interrupted?"cancelled":exit_code?"error":unavailable?"partial":"complete";
    if (json) printf("\n],\"state\":\"%s\",\"execute_available\":%s}\n",state,unavailable?"false":"true");
    else printf("# state: %s\n# execute_available: %s\n",state,unavailable?"false":"true");
    mb_destroy(ctx);
    if (ferror(stdout) && !exit_code) exit_code=1;
    return exit_code;
}
