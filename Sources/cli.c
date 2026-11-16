#include "benchmark.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <errno.h>

static volatile sig_atomic_t interrupted;
static void stop(int sig) { (void)sig; interrupted=1; }
static void usage(const char *name) {
    fprintf(stderr,"Usage: %s [--mode read|write|execute|all] [--max-mib 1..1024] [--quick]\n",name);
}
int main(int argc, char **argv) {
    size_t max=64*1024*1024; double seconds=0.025; int selected=-1;
    for (int i=1; i<argc; ++i) {
        if (!strcmp(argv[i],"--quick")) seconds=0.005;
        else if (!strcmp(argv[i],"--help")) { usage(argv[0]); return 0; }
        else if (!strcmp(argv[i],"--mode") && i+1<argc) {
            const char *mode=argv[++i];
            if (!strcmp(mode,"read")) selected=MB_READ;
            else if (!strcmp(mode,"write")) selected=MB_WRITE;
            else if (!strcmp(mode,"execute")) selected=MB_EXECUTE;
            else if (!strcmp(mode,"all")) selected=-1;
            else { usage(argv[0]); return 2; }
        } else if (!strcmp(argv[i],"--max-mib") && i+1<argc) {
            char *end; errno=0; long mib=strtol(argv[++i],&end,10);
            if (errno || *end || end==argv[i] || mib<1 || mib>1024) { usage(argv[0]); return 2; }
            max=(size_t)mib*1024*1024;
        } else { usage(argv[0]); return 2; }
    }
    signal(SIGINT,stop); signal(SIGTERM,stop);
    mb_context *ctx=mb_create(); if (!ctx) return 1;
    fprintf(stderr,"%s; %s; one thread; samples=3; seconds/sample=%.3f\n",mb_method_version(),mb_architecture(),seconds);
    puts("operation,bytes,median_GB_s,min_GB_s,max_GB_s,sample_seconds,passes,samples");
    size_t sizes[80], count=mb_sizes(max,sizes,80); int exit_code=0;
    const char *names[]={"read","write","execute_proxy"};
    int execute_disabled=0;
    for (size_t i=0; i<count && !interrupted; ++i) {
        for (int op=MB_READ; op<=MB_EXECUTE && !interrupted; ++op) {
            if (selected>=0 && op!=selected) continue;
            if (op==MB_EXECUTE && (execute_disabled || sizes[i]>64*1024*1024)) continue;
            mb_result result;
            mb_status status=mb_measure(ctx,(mb_operation)op,sizes[i],seconds,3,&result);
            if (status==MB_UNAVAILABLE) {
                fprintf(stderr,"execute unavailable: %s\n",mb_error(ctx)); execute_disabled=1;
                if (selected==MB_EXECUTE) exit_code=1;
                continue;
            }
            if (status!=MB_OK) { fprintf(stderr,"%s\n",mb_error(ctx)); exit_code=1; goto done; }
            printf("%s,%zu,%.6f,%.6f,%.6f,%.9f,%llu,%u\n",names[op],result.bytes,
                   result.gb_per_second,result.minimum_gb_per_second,result.maximum_gb_per_second,
                   result.seconds,(unsigned long long)result.passes,result.samples);
            fflush(stdout);
        }
    }
done:
    if (interrupted) exit_code=130;
    mb_destroy(ctx); return exit_code;
}
