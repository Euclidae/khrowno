#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <errno.h>

#ifdef HAVE_LIBSODIUM
#include <sodium.h>
#endif

#ifdef HAVE_CURL
#include <curl/curl.h>
#endif

#include <zlib.h>

// C bindings for KrownoBackup Tool v0.3.0
// This file provides C wrapper functions for libraries that are easier
// to call from C than from Zig directly.

// Initialize libsodium if available
int krowno_init_crypto(void) {
#ifdef HAVE_LIBSODIUM
    if (sodium_init() < 0) {
        fprintf(stderr, "Failed to initialize libsodium\n");
        return -1;
    }
    return 0;
#else
    fprintf(stderr, "libsodium not available\n");
    return -1;
#endif
}


int krowno_init_network(void) {
#ifdef HAVE_CURL
    CURLcode res = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (res != CURLE_OK) {
        fprintf(stderr, "Failed to initialize curl: %s\n", curl_easy_strerror(res));
        return -1;
    }
    return 0;
#else
    fprintf(stderr, "curl not available\n");
    return -1;
#endif
}


void krowno_cleanup_network(void) {
#ifdef HAVE_CURL
    curl_global_cleanup();
#endif
}

void krowno_secure_zero(void *ptr, size_t len) {
#ifdef HAVE_LIBSODIUM
    sodium_memzero(ptr, len);
#else
    volatile unsigned char *p = ptr;
    while (len--) {
        *p++ = 0;
    }
#endif
}

int krowno_file_exists(const char *path) {
    if (!path) return 0;
    return access(path, R_OK) == 0 ? 1 : 0;
}

int krowno_mkdir_recursive(const char *path, mode_t mode) {
    if (!path) return -1;
    
    char *path_copy = strdup(path);
    if (!path_copy) return -1;
    
    char *p = path_copy;
    int ret = 0;
    
    if (*p == '/') p++;
    
    while ((p = strchr(p, '/'))) {
        *p = '\0';
        if (mkdir(path_copy, mode) != 0 && errno != EEXIST) {
            ret = -1;
            break;
        }
        *p++ = '/';
    }
    
    if (ret == 0 && mkdir(path_copy, mode) != 0 && errno != EEXIST) {
        ret = -1;
    }
    
    free(path_copy);
    return ret;
}

long krowno_file_size(const char *path) {
    if (!path) return -1;
    
    struct stat st;
    if (stat(path, &st) == 0) {
        return st.st_size;
    }
    return -1;
}

struct krowno_http_response {
    char *data;
    size_t size;
    long status_code;
};

#ifdef HAVE_CURL
static size_t krowno_curl_write_callback(void *contents, size_t size, size_t nmemb, struct krowno_http_response *response) {
    size_t realsize = size * nmemb;
    char *ptr = realloc(response->data, response->size + realsize + 1);
    
    if (!ptr) {
        fprintf(stderr, "Not enough memory (realloc returned NULL)\n");
        return 0;
    }
    
    response->data = ptr;
    memcpy(&(response->data[response->size]), contents, realsize);
    response->size += realsize;
    response->data[response->size] = 0;
    
    return realsize;
}
#endif

struct krowno_http_response* krowno_http_get(const char *url, const char *user_agent, int timeout_seconds) {
#ifdef HAVE_CURL
    if (!url) return NULL;
    
    struct krowno_http_response *response = calloc(1, sizeof(struct krowno_http_response));
    if (!response) return NULL;
    
    CURL *curl = curl_easy_init();
    if (!curl) {
        free(response);
        return NULL;
    }
    
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, krowno_curl_write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, response);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, (long)timeout_seconds);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    
    if (user_agent) {
        curl_easy_setopt(curl, CURLOPT_USERAGENT, user_agent);
    }
    
    CURLcode res = curl_easy_perform(curl);
    
    if (res == CURLE_OK) {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response->status_code);
    } else {
        response->status_code = 0; // Error indicator
    }
    
    curl_easy_cleanup(curl);
    return response;
#else
    (void)url;
    (void)user_agent;
    (void)timeout_seconds;
    return NULL;
#endif
}

void krowno_http_response_free(struct krowno_http_response *response) {
    if (response) {
        if (response->data) {
            free(response->data);
        }
        free(response);
    }
}

int krowno_random_bytes(unsigned char *buf, size_t len) {
#ifdef HAVE_LIBSODIUM
    randombytes_buf(buf, len);
    return 0;
#else
    // Fallback to reading from /dev/urandom
    FILE *f = fopen("/dev/urandom", "rb");
    if (!f) return -1;
    
    size_t read = fread(buf, 1, len, f);
    fclose(f);
    
    return (read == len) ? 0 : -1;
#endif
}

int krowno_hash_password(const char *password, const unsigned char *salt, size_t salt_len,
                        unsigned char *hash, size_t hash_len,
                        unsigned int iterations, size_t memory_kb, unsigned int parallelism) {
#ifdef HAVE_LIBSODIUM
    if (!password || !salt || !hash || salt_len < 16 || hash_len < 32) {
        return -1;
    }
    
    // Use Argon2id variant
    return crypto_pwhash(hash, hash_len, password, strlen(password), salt,
                        iterations, memory_kb * 1024, crypto_pwhash_ALG_ARGON2ID);
#else
    (void)password;
    (void)salt;
    (void)salt_len;
    (void)hash;
    (void)hash_len;
    (void)iterations;
    (void)memory_kb;
    (void)parallelism;
    return -1;
#endif
}

int krowno_get_hostname(char *hostname, size_t len) {
    return gethostname(hostname, len);
}

int krowno_get_username(char *username, size_t len) {
    const char *user = getenv("USER");
    if (!user) user = getenv("LOGNAME");
    if (!user) return -1;
    
    size_t user_len = strlen(user);
    if (user_len >= len) return -1;
    
    strcpy(username, user);
    return 0;
}

int krowno_execute_command(const char *command, char **output, size_t *output_len) {
    if (!command) return -1;
    
    FILE *pipe = popen(command, "r");
    if (!pipe) return -1;
    
    char *result = NULL;
    size_t result_size = 0;
    size_t result_capacity = 1024;
    
    result = malloc(result_capacity);
    if (!result) {
        pclose(pipe);
        return -1;
    }
    
    char buffer[256];
    while (fgets(buffer, sizeof(buffer), pipe)) {
        size_t len = strlen(buffer);
        if (result_size + len >= result_capacity) {
            result_capacity *= 2;
            char *new_result = realloc(result, result_capacity);
            if (!new_result) {
                free(result);
                pclose(pipe);
                return -1;
            }
            result = new_result;
        }
        strcpy(result + result_size, buffer);
        result_size += len;
    }
    
    int exit_code = pclose(pipe);
    
    if (output) *output = result;
    if (output_len) *output_len = result_size;
    
    return WEXITSTATUS(exit_code);
}

void krowno_free_command_output(char *output) {
    if (output) {
        free(output);
    }
}

long long krowno_timestamp(void) {
    return (long long)time(NULL);
}

int krowno_is_root(void) {
    return getuid() == 0 ? 1 : 0;
}

const char* krowno_get_platform(void) {
#if defined(__linux__)
    return "linux";
#elif defined(__APPLE__)
    return "macos";
#elif defined(__FreeBSD__)
    return "freebsd";
#elif defined(__OpenBSD__)
    return "openbsd";
#elif defined(__NetBSD__)
    return "netbsd";
#else
    return "unknown";
#endif
}

const char* krowno_get_architecture(void) {
#if defined(__x86_64__) || defined(_M_X64)
    return "x86_64";
#elif defined(__i386__) || defined(_M_IX86)
    return "i386";
#elif defined(__aarch64__)
    return "aarch64";
#elif defined(__arm__)
    return "arm";
#elif defined(__riscv)
    return "riscv64";
#else
    return "unknown";
#endif
}


const char* krowno_version(void) {
    return "0.3.0";
}

const char* krowno_build_info(void) {
    static char build_info[512];
    snprintf(build_info, sizeof(build_info),
        "Krowno v%s built on %s %s for %s-%s",
        krowno_version(),
        __DATE__, __TIME__,
        krowno_get_platform(),
        krowno_get_architecture()
    );
    return build_info;
}

// ----------------------------------------------------------------------------
// Compression helpers (zlib)
// ----------------------------------------------------------------------------

// Note: I tried doing streaming deflate from Zig; the zlib state machine is a
// little fiddly through FFI, and frankly it's easier (and safer) to wrap here.

int krowno_deflate(const unsigned char *input, size_t input_len,
                   unsigned char **output, size_t *output_len, int level) {
    if (!input || input_len == 0 || !output || !output_len) return -1;

    uLongf bound = compressBound((uLong)input_len);
    unsigned char *out = (unsigned char*)malloc(bound);
    if (!out) return -1;

    int zres = compress2(out, &bound, input, (uLong)input_len, level);
    if (zres != Z_OK) {
        free(out);
        return -1;
    }

    *output = out;
    *output_len = (size_t)bound;
    return 0;
}

int krowno_inflate(const unsigned char *input, size_t input_len,
                   unsigned char **output, size_t *output_len) {
    if (!input || input_len == 0 || !output || !output_len) return -1;

    size_t cap = input_len * 4;
    if (cap < 1024) cap = 1024;

    unsigned char *out = NULL;
    int zres = Z_BUF_ERROR;
    for (int i = 0; i < 6; ++i) {
        free(out);
        out = (unsigned char*)malloc(cap);
        if (!out) return -1;

        uLongf dest_len = (uLongf)cap;
        zres = uncompress(out, &dest_len, input, (uLong)input_len);
        if (zres == Z_OK) {
            *output = out;
            *output_len = (size_t)dest_len;
            return 0;
        }
        cap *= 2;
    }

    free(out);
    return -1;
}

void krowno_free_buffer(void *ptr) {
    if (ptr) free(ptr);
}