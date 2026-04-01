/*
 * sysinfo.c - Detailed System Hardware Information Gatherer
 *
 * Prints comprehensive hardware specs by combining fast sysctl queries
 * with targeted system_profiler calls for data not available elsewhere.
 *
 * Build: cc -O2 -o sysinfo sysinfo.c -framework IOKit -framework CoreFoundation
 * Usage: ./sysinfo
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/statvfs.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

/* ------------------------------------------------------------------ */
/* sysctl helpers                                                      */
/* ------------------------------------------------------------------ */
static int get_int(const char *name) {
    int val = 0; size_t len = sizeof(val);
    sysctlbyname(name, &val, &len, NULL, 0);
    return val;
}

static long long get_ll(const char *name) {
    long long val = 0; size_t len = sizeof(val);
    sysctlbyname(name, &val, &len, NULL, 0);
    return val;
}

static void get_str(const char *name, char *buf, size_t sz) {
    size_t len = sz;
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0)
        snprintf(buf, sz, "N/A");
}

static int has_feature(const char *name) {
    int val = 0; size_t len = sizeof(val);
    if (sysctlbyname(name, &val, &len, NULL, 0) != 0) return -1;
    return val;
}

/* ------------------------------------------------------------------ */
/* IOKit helper: get a string property from a matching service          */
/* ------------------------------------------------------------------ */
static int iokit_get_string(const char *match_class, const char *prop_key,
                            char *buf, size_t bufsz) {
    io_iterator_t iter;
    kern_return_t kr;
    CFMutableDictionaryRef match = IOServiceMatching(match_class);
    if (!match) return -1;

    kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) return -1;

    io_service_t svc;
    int found = 0;
    while ((svc = IOIteratorNext(iter)) != 0) {
        CFStringRef key_str = CFStringCreateWithCString(NULL, prop_key,
                                                         kCFStringEncodingUTF8);
        CFTypeRef ref = IORegistryEntryCreateCFProperty(
            svc, key_str, kCFAllocatorDefault, 0);
        CFRelease(key_str);
        if (ref) {
            if (CFGetTypeID(ref) == CFStringGetTypeID()) {
                CFStringGetCString(ref, buf, bufsz, kCFStringEncodingUTF8);
                found = 1;
            } else if (CFGetTypeID(ref) == CFDataGetTypeID()) {
                CFIndex len = CFDataGetLength(ref);
                if (len > (CFIndex)(bufsz - 1)) len = bufsz - 1;
                memcpy(buf, CFDataGetBytePtr(ref), len);
                buf[len] = '\0';
                /* Strip trailing whitespace */
                while (len > 0 && (buf[len-1] == ' ' || buf[len-1] == '\0')) {
                    buf[--len] = '\0';
                }
                found = 1;
            }
            CFRelease(ref);
        }
        IOObjectRelease(svc);
        if (found) break;
    }
    IOObjectRelease(iter);
    return found ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/* NVMe controller details via IOKit                                   */
/* ------------------------------------------------------------------ */
static void print_nvme_info(void) {
    io_iterator_t iter;
    CFMutableDictionaryRef match = IOServiceMatching("IONVMeController");
    if (!match) return;

    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) return;

    io_service_t svc;
    while ((svc = IOIteratorNext(iter)) != 0) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {

            /* Model */
            CFTypeRef ref = CFDictionaryGetValue(props, CFSTR("Model Number"));
            if (ref && CFGetTypeID(ref) == CFStringGetTypeID()) {
                char model[256];
                CFStringGetCString(ref, model, sizeof(model), kCFStringEncodingUTF8);
                printf("  Model:             %s\n", model);
            } else if (ref && CFGetTypeID(ref) == CFDataGetTypeID()) {
                char model[256] = {0};
                CFIndex len = CFDataGetLength(ref);
                if (len > 255) len = 255;
                memcpy(model, CFDataGetBytePtr(ref), len);
                /* Trim */
                while (len > 0 && (model[len-1] == ' ' || model[len-1] == '\0')) model[--len] = '\0';
                printf("  Model:             %s\n", model);
            }

            /* Firmware */
            ref = CFDictionaryGetValue(props, CFSTR("Firmware Revision"));
            if (ref && CFGetTypeID(ref) == CFStringGetTypeID()) {
                char fw[128];
                CFStringGetCString(ref, fw, sizeof(fw), kCFStringEncodingUTF8);
                printf("  Firmware:          %s\n", fw);
            }

            /* NVMe revision */
            ref = CFDictionaryGetValue(props, CFSTR("NVMe Revision Supported"));
            if (ref && CFGetTypeID(ref) == CFStringGetTypeID()) {
                char rev[64];
                CFStringGetCString(ref, rev, sizeof(rev), kCFStringEncodingUTF8);
                printf("  NVMe Revision:     %s\n", rev);
            }

            /* Protocol */
            ref = CFDictionaryGetValue(props, CFSTR("Physical Interconnect"));
            if (ref && CFGetTypeID(ref) == CFStringGetTypeID()) {
                char proto[128];
                CFStringGetCString(ref, proto, sizeof(proto), kCFStringEncodingUTF8);
                printf("  Bus/Protocol:      %s\n", proto);
            }

            /* Max IO sizes */
            ref = CFDictionaryGetValue(props, CFSTR("IOMaximumByteCountRead"));
            if (ref && CFGetTypeID(ref) == CFNumberGetTypeID()) {
                long long val;
                CFNumberGetValue(ref, kCFNumberLongLongType, &val);
                printf("  Max Read Request:  %lld KB\n", val / 1024);
            }
            ref = CFDictionaryGetValue(props, CFSTR("IOMaximumByteCountWrite"));
            if (ref && CFGetTypeID(ref) == CFNumberGetTypeID()) {
                long long val;
                CFNumberGetValue(ref, kCFNumberLongLongType, &val);
                printf("  Max Write Request: %lld KB\n", val / 1024);
            }

            /* Queue depth */
            ref = CFDictionaryGetValue(props, CFSTR("IOCommandPoolSize"));
            if (ref && CFGetTypeID(ref) == CFNumberGetTypeID()) {
                long long val;
                CFNumberGetValue(ref, kCFNumberLongLongType, &val);
                printf("  Queue Depth:       %lld\n", val);
            }

            /* Controller characteristics -- NAND details */
            ref = CFDictionaryGetValue(props, CFSTR("Controller Characteristics"));
            if (ref && CFGetTypeID(ref) == CFDictionaryGetTypeID()) {
                CFDictionaryRef cc = (CFDictionaryRef)ref;

                CFTypeRef v = CFDictionaryGetValue(cc, CFSTR("vendor-name"));
                if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
                    char vname[128];
                    CFStringGetCString(v, vname, sizeof(vname), kCFStringEncodingUTF8);
                    /* Trim */
                    size_t l = strlen(vname);
                    while (l > 0 && vname[l-1] == ' ') vname[--l] = '\0';
                    printf("  NAND Vendor:       %s\n", vname);
                }

                v = CFDictionaryGetValue(cc, CFSTR("nand-marketing-name"));
                if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
                    char nname[128];
                    CFStringGetCString(v, nname, sizeof(nname), kCFStringEncodingUTF8);
                    size_t l = strlen(nname);
                    while (l > 0 && nname[l-1] == ' ') nname[--l] = '\0';
                    printf("  NAND Type:         %s\n", nname);
                }

                v = CFDictionaryGetValue(cc, CFSTR("cell-type"));
                if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
                    long long ct;
                    CFNumberGetValue(v, kCFNumberLongLongType, &ct);
                    const char *label = ct == 1 ? "SLC" : ct == 2 ? "MLC" : ct == 3 ? "TLC" : ct == 4 ? "QLC" : "unknown";
                    printf("  Cell Type:         %s (%lld bits/cell)\n", label, ct);
                }

                v = CFDictionaryGetValue(cc, CFSTR("num-bus"));
                if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
                    long long nb;
                    CFNumberGetValue(v, kCFNumberLongLongType, &nb);
                    printf("  NAND Buses:        %lld\n", nb);
                }

                v = CFDictionaryGetValue(cc, CFSTR("num-dip"));
                if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
                    long long nd;
                    CFNumberGetValue(v, kCFNumberLongLongType, &nd);
                    printf("  NAND Dies:         %lld\n", nd);
                }

                v = CFDictionaryGetValue(cc, CFSTR("page-size"));
                if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
                    long long ps;
                    CFNumberGetValue(v, kCFNumberLongLongType, &ps);
                    printf("  NAND Page Size:    %lld bytes\n", ps);
                }

                v = CFDictionaryGetValue(cc, CFSTR("Encryption Type"));
                if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
                    char enc[64];
                    CFStringGetCString(v, enc, sizeof(enc), kCFStringEncodingUTF8);
                    printf("  Encryption:        %s\n", enc);
                }

                v = CFDictionaryGetValue(cc, CFSTR("capacity"));
                if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
                    long long cap;
                    CFNumberGetValue(v, kCFNumberLongLongType, &cap);
                    printf("  Raw Capacity:      %.0f GB\n", (double)cap / 1e9);
                }
            }

            CFRelease(props);
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(iter);
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */
int main(void) {
    char buf[256];

    printf("========================================================\n");
    printf("  System Hardware Information\n");
    printf("========================================================\n\n");

    /* ---- Machine Identifier ---- */
    {
        char uuid[256] = "unknown";
        size_t uuid_len = sizeof(uuid);
        sysctlbyname("kern.uuid", uuid, &uuid_len, NULL, 0);
        printf("Machine ID:          %s\n\n", uuid);
    }

    /* ---- CPU ---- */
    printf("--- CPU ---\n");
    get_str("machdep.cpu.brand_string", buf, sizeof(buf));
    printf("  Chip:              %s\n", buf);

    get_str("hw.targettype", buf, sizeof(buf));
    printf("  Board ID:          %s\n", buf);

    int ncpu = get_int("hw.ncpu");
    int pcpu = get_int("hw.physicalcpu");
    printf("  Physical Cores:    %d\n", pcpu);
    printf("  Logical Cores:     %d\n", ncpu);

    int nperf = get_int("hw.nperflevels");
    for (int lvl = 0; lvl < nperf; lvl++) {
        char key[128];
        snprintf(key, sizeof(key), "hw.perflevel%d.name", lvl);
        get_str(key, buf, sizeof(buf));

        snprintf(key, sizeof(key), "hw.perflevel%d.physicalcpu", lvl);
        int cores = get_int(key);
        snprintf(key, sizeof(key), "hw.perflevel%d.l1dcachesize", lvl);
        int l1d = get_int(key);
        snprintf(key, sizeof(key), "hw.perflevel%d.l1icachesize", lvl);
        int l1i = get_int(key);
        snprintf(key, sizeof(key), "hw.perflevel%d.l2cachesize", lvl);
        int l2 = get_int(key);
        snprintf(key, sizeof(key), "hw.perflevel%d.cpusperl2", lvl);
        int cpus_per_l2 = get_int(key);

        printf("  %s cores:     %d\n", buf, cores);
        printf("    L1d:             %d KB\n", l1d / 1024);
        printf("    L1i:             %d KB\n", l1i / 1024);
        printf("    L2:              %d MB (shared by %d cores)\n", l2 / (1024*1024), cpus_per_l2);
    }

    long long clsize = get_ll("hw.cachelinesize");
    printf("  Cache Line:        %lld bytes\n", clsize);
    printf("  Page Size:         %lld bytes\n", get_ll("hw.pagesize"));
    printf("  Timebase Freq:     %lld MHz\n", get_ll("hw.tbfrequency") / 1000000);

    /* CPU clock speeds via IOKit CPUFrequencyMHz and sysctl */
    {
        /* P-core max frequency */
        char pfreq[64] = "";
        if (iokit_get_string("AppleARMIODevice", "voltage-states5-sram", pfreq, sizeof(pfreq)) != 0)
            pfreq[0] = '\0';

        /* Try sysctl-based clock keys (available on some macOS versions) */
        long long cpu_max_mhz = 0;
        {
            /* hw.cpufrequency_max is present on Intel; on Apple Silicon use IOKit */
            long long v = get_ll("hw.cpufrequency_max");
            if (v > 0) cpu_max_mhz = v / 1000000LL;
        }
        if (cpu_max_mhz > 0)
            printf("  CPU Max Freq:      %lld MHz\n", cpu_max_mhz);

        /* Read P-core and E-core frequencies from IOKit performance state tables.
         * The AppleARMIODevice "pmgr" node exposes voltage-states tables:
         *   voltage-states1-sram  = E-core states (freq_hz, voltage_mv pairs)
         *   voltage-states5-sram  = P-core states (freq_hz, voltage_mv pairs)
         * Each entry is 2 x uint32_t: [freq_hz, voltage_mv].
         * We scan all matching IOKit services for the table properties.
         */
        io_iterator_t iter2;
        CFMutableDictionaryRef match2 = IOServiceMatching("AppleARMIODevice");
        if (match2 && IOServiceGetMatchingServices(kIOMainPortDefault, match2, &iter2) == KERN_SUCCESS) {
            io_service_t svc2;
            while ((svc2 = IOIteratorNext(iter2)) != 0) {
                /* P-core states */
                CFTypeRef pref = IORegistryEntryCreateCFProperty(
                    svc2, CFSTR("voltage-states5-sram"), kCFAllocatorDefault, 0);
                if (pref && CFGetTypeID(pref) == CFDataGetTypeID()) {
                    CFIndex dlen = CFDataGetLength(pref);
                    const uint32_t *words = (const uint32_t *)CFDataGetBytePtr(pref);
                    long nstates = dlen / 8;  /* each state: freq(4) + voltage(4) */
                    if (nstates > 0) {
                        /* Last state = highest frequency */
                        uint32_t max_hz = words[(nstates - 1) * 2];
                        printf("  P-core Max Freq:   %u MHz\n", max_hz / 1000000u);
                    }
                    CFRelease(pref);
                }

                /* E-core states */
                CFTypeRef eref = IORegistryEntryCreateCFProperty(
                    svc2, CFSTR("voltage-states1-sram"), kCFAllocatorDefault, 0);
                if (eref && CFGetTypeID(eref) == CFDataGetTypeID()) {
                    CFIndex dlen = CFDataGetLength(eref);
                    const uint32_t *words = (const uint32_t *)CFDataGetBytePtr(eref);
                    long nstates = dlen / 8;
                    if (nstates > 0) {
                        uint32_t max_hz = words[(nstates - 1) * 2];
                        printf("  E-core Max Freq:   %u MHz\n", max_hz / 1000000u);
                    }
                    CFRelease(eref);
                }

                IOObjectRelease(svc2);
            }
            IOObjectRelease(iter2);
        }
    }

    /* ARM features */
    printf("  ISA Features:      ");
    const char *features[] = {
        "FEAT_FP16", "FEAT_BF16", "FEAT_I8MM", "FEAT_DotProd",
        "FEAT_SHA3", "FEAT_SHA512", "FEAT_AES",
        "FEAT_LSE", "FEAT_LSE2", "FEAT_BTI", "FEAT_MTE",
        "FEAT_SME", "FEAT_SME2", NULL
    };
    int first = 1;
    for (int i = 0; features[i]; i++) {
        char key[128];
        snprintf(key, sizeof(key), "hw.optional.arm.%s", features[i]);
        if (has_feature(key) == 1) {
            printf("%s%s", first ? "" : " ", features[i]);
            first = 0;
        }
    }
    printf("\n");

    int sme_svl = get_int("hw.optional.arm.sme_max_svl_b");
    if (sme_svl > 0)
        printf("  SME Max SVL:       %d bytes (%d bits)\n", sme_svl, sme_svl * 8);

    /* ---- Memory ---- */
    printf("\n--- Memory ---\n");
    long long memsize = get_ll("hw.memsize");
    long long memsize_usable = get_ll("hw.memsize_usable");
    printf("  Total:             %.1f GB\n", memsize / (1024.0*1024.0*1024.0));
    if (memsize_usable > 0)
        printf("  Usable:            %.1f GB\n", memsize_usable / (1024.0*1024.0*1024.0));

    /* system_profiler for memory type (fast for this small query) */
    FILE *fp = popen("system_profiler SPMemoryDataType 2>/dev/null", "r");
    if (fp) {
        char line[512];
        while (fgets(line, sizeof(line), fp)) {
            /* Trim leading whitespace */
            char *p = line;
            while (*p == ' ' || *p == '\t') p++;
            /* Remove trailing newline */
            size_t len = strlen(p);
            if (len > 0 && p[len-1] == '\n') p[len-1] = '\0';

            if (strncmp(p, "Type:", 5) == 0) {
                printf("  Type:              %s\n", p + 6);
            } else if (strncmp(p, "Manufacturer:", 13) == 0) {
                printf("  Manufacturer:      %s\n", p + 14);
            } else if (strncmp(p, "Speed:", 6) == 0) {
                printf("  Speed:             %s\n", p + 7);
            } else if (strncmp(p, "Configured Speed:", 17) == 0) {
                printf("  Configured Speed:  %s\n", p + 18);
            }
        }
        pclose(fp);
    }

    /* ---- Storage ---- */
    printf("\n--- Storage (NVMe) ---\n");
    print_nvme_info();

    /* Block size from statvfs */
    {
        struct statvfs st;
        if (statvfs("/", &st) == 0)
            printf("  Block Size:        %lu bytes\n", (unsigned long)st.f_bsize);
        else
            printf("  Block Size:        4096 bytes (default)\n");
    }
    printf("  TRIM:              Supported\n");

    /* ---- GPU ---- */
    printf("\n--- GPU ---\n");
    fp = popen("system_profiler SPDisplaysDataType 2>/dev/null", "r");
    if (fp) {
        char line[512];
        while (fgets(line, sizeof(line), fp)) {
            char *p = line;
            while (*p == ' ' || *p == '\t') p++;
            size_t len = strlen(p);
            if (len > 0 && p[len-1] == '\n') p[len-1] = '\0';

            if (strncmp(p, "Chipset Model:", 14) == 0) {
                printf("  Chipset:           %s\n", p + 15);
            } else if (strncmp(p, "Total Number of Cores:", 22) == 0) {
                printf("  GPU Cores:         %s\n", p + 23);
            } else if (strncmp(p, "Metal Support:", 14) == 0) {
                printf("  Metal Support:     %s\n", p + 15);
            } else if (strncmp(p, "Vendor:", 7) == 0) {
                printf("  Vendor:            %s\n", p + 8);
            }
        }
        pclose(fp);
    }

    /* GPU max frequency from IOKit voltage-states9-sram (GPU perf states) */
    {
        io_iterator_t giter;
        CFMutableDictionaryRef gmatch = IOServiceMatching("AppleARMIODevice");
        if (gmatch && IOServiceGetMatchingServices(kIOMainPortDefault, gmatch, &giter) == KERN_SUCCESS) {
            io_service_t gsvc;
            int found_gpu_freq = 0;
            while ((gsvc = IOIteratorNext(giter)) != 0 && !found_gpu_freq) {
                CFTypeRef gref = IORegistryEntryCreateCFProperty(
                    gsvc, CFSTR("voltage-states9"), kCFAllocatorDefault, 0);
                if (!gref)
                    gref = IORegistryEntryCreateCFProperty(
                        gsvc, CFSTR("voltage-states9-sram"), kCFAllocatorDefault, 0);
                if (gref && CFGetTypeID(gref) == CFDataGetTypeID()) {
                    CFIndex dlen = CFDataGetLength(gref);
                    const uint32_t *words = (const uint32_t *)CFDataGetBytePtr(gref);
                    long nstates = dlen / 8;
                    if (nstates > 0) {
                        uint32_t max_hz = words[(nstates - 1) * 2];
                        if (max_hz > 1000000) {  /* sanity: > 1 MHz */
                            printf("  GPU Max Freq:      %u MHz\n", max_hz / 1000000u);
                            found_gpu_freq = 1;
                        }
                    }
                    CFRelease(gref);
                }
                IOObjectRelease(gsvc);
            }
            IOObjectRelease(giter);
        }
    }

    /* ---- OS ---- */
    printf("\n--- OS ---\n");
    fp = popen("sw_vers 2>/dev/null", "r");
    if (fp) {
        char line[256];
        while (fgets(line, sizeof(line), fp)) {
            char *p = line;
            size_t len = strlen(p);
            if (len > 0 && p[len-1] == '\n') p[len-1] = '\0';
            printf("  %s\n", p);
        }
        pclose(fp);
    }

    printf("\n========================================================\n");
    return 0;
}
