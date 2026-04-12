/*
 * Copyright 2025 International Digital Economy Academy
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef _WIN32

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <moonbit.h>

// TODO: are these stable?
#define BIO_TYPE_NONE 0
#define SSL_VERIFY_NONE 0x00
#define SSL_VERIFY_PEER 0x01
#define BIO_CTRL_FLUSH 11
#define SSL_CTRL_MODE 33
#define SSL_CTRL_SET_MIN_PROTO_VERSION 123
#define SSL_CTRL_SET_MAX_PROTO_VERSION 124
#define SSL_MODE_ENABLE_PARTIAL_WRITE 0x00000001U
#define SSL_CTRL_SET_TLSEXT_HOSTNAME 55
#define TLSEXT_NAMETYPE_host_name 0
#define TLS1_2_VERSION 0x0303
#define X509_V_FLAG_CRL_CHECK 0x4
#define X509_V_FLAG_CRL_CHECK_ALL 0x8

typedef struct BIO_METHOD BIO_METHOD;
typedef struct BIO BIO;
typedef struct SSL SSL;
typedef struct SSL_CTX SSL_CTX;
typedef struct SSL_METHOD SSL_METHOD;
typedef struct X509 X509;
typedef struct X509_STORE X509_STORE;
typedef struct X509_VERIFY_PARAM X509_VERIFY_PARAM;
typedef struct evp_md_st EVP_MD;

#define IMPORTED_OPEN_SSL_FUNCTIONS\
  IMPORT_FUNC(BIO_METHOD*, BIO_meth_new, (int type, const char *name))\
  IMPORT_FUNC(int, BIO_meth_set_write, (BIO_METHOD *biom, int (*write)(BIO *, const void *, int)))\
  IMPORT_FUNC(int, BIO_meth_set_read, (BIO_METHOD *biom, int (*read)(BIO *, void *, int)))\
  IMPORT_FUNC(int, BIO_meth_set_ctrl, (BIO_METHOD *biom, long (*ctrl)(BIO *, int, long, void *)))\
  IMPORT_FUNC(int, BIO_meth_set_destroy, (BIO_METHOD *biom, int (*destroy)(BIO *)))\
  IMPORT_FUNC(BIO *, BIO_new, (const BIO_METHOD *type))\
  IMPORT_FUNC(void, BIO_set_data, (BIO *bio, void *data))\
  IMPORT_FUNC(void *, BIO_get_data, (BIO *bio))\
  IMPORT_FUNC(void, BIO_set_init, (BIO *bio, int init))\
  IMPORT_FUNC(void, BIO_set_flags, (BIO *bio, int flags))\
  IMPORT_FUNC(void, BIO_set_shutdown, (BIO *bio, int shutdown))\
  IMPORT_FUNC(SSL *, SSL_new, (SSL_CTX *ctx))\
  IMPORT_FUNC(void, SSL_set_bio, (SSL *s, BIO *rbio, BIO *wbio))\
  IMPORT_FUNC(int, SSL_connect, (SSL *ssl))\
  IMPORT_FUNC(void, SSL_set_verify, (SSL *ssl, int mode, int (*verify_cb)(int, void*)))\
  IMPORT_FUNC(int, SSL_set1_host, (SSL *ssl, const char *host))\
  IMPORT_FUNC(long, SSL_ctrl, (SSL *ssl, int cmd, long larg, void *parg))\
  IMPORT_FUNC(int, SSL_accept, (SSL *ssl))\
  IMPORT_FUNC(int, SSL_use_certificate_file, (SSL *ssl, const char *file, int type))\
  IMPORT_FUNC(int, SSL_use_PrivateKey_file, (SSL *ssl, const char *file, int type))\
  IMPORT_FUNC(int, SSL_read, (SSL *ssl, void *buf, int num))\
  IMPORT_FUNC(int, SSL_write, (SSL *ssl, void *buf, int num))\
  IMPORT_FUNC(int, SSL_get_error, (SSL *ssl, int ret))\
  IMPORT_FUNC(int, SSL_shutdown, (SSL *ssl))\
  IMPORT_FUNC(void, SSL_free, (SSL *ssl))\
  IMPORT_FUNC(X509 *, SSL_get1_peer_certificate, (const SSL *ssl))\
  IMPORT_FUNC(SSL_CTX *, SSL_CTX_new, (const SSL_METHOD*))\
  IMPORT_FUNC(void, SSL_CTX_free, (SSL_CTX *))\
  IMPORT_FUNC(SSL_METHOD *, TLS_client_method, (void))\
  IMPORT_FUNC(SSL_METHOD *, TLS_server_method, (void))\
  IMPORT_FUNC(long, SSL_CTX_ctrl, (SSL_CTX *ctx, int cmd, long larg, void *parg))\
  IMPORT_FUNC(void, SSL_CTX_set_verify, (SSL_CTX *ctx, int mode, int (*verify_cb)(int, void*)))\
  IMPORT_FUNC(int, SSL_CTX_set_default_verify_paths, (SSL_CTX *ctx))\
  IMPORT_FUNC(int, SSL_CTX_load_verify_locations, (SSL_CTX *ctx, const char *CAfile, const char *CApath))\
  IMPORT_FUNC(int, SSL_CTX_use_PrivateKey_file, (SSL_CTX *ctx, const char *file, int type))\
  IMPORT_FUNC(int, SSL_CTX_use_certificate_file, (SSL_CTX *ctx, const char *file, int type))\
  IMPORT_FUNC(void, SSL_CTX_set_default_passwd_cb, (SSL_CTX *ctx, int (*cb)(char *, int, int, void *)))\
  IMPORT_FUNC(void, SSL_CTX_set_default_passwd_cb_userdata, (SSL_CTX *ctx, void *u))\
  IMPORT_FUNC(int, SSL_CTX_check_private_key, (const SSL_CTX *ctx))\
  IMPORT_FUNC(X509_STORE *, SSL_CTX_get_cert_store, (const SSL_CTX *ctx))\
  IMPORT_FUNC(int, X509_STORE_load_locations, (X509_STORE *ctx, const char *file, const char *dir))\
  IMPORT_FUNC(int, X509_STORE_set_flags, (X509_STORE *ctx, unsigned long flags))\
  IMPORT_FUNC(X509_VERIFY_PARAM *, SSL_get0_param, (SSL *ssl))\
  IMPORT_FUNC(int, X509_VERIFY_PARAM_set1_ip_asc, (X509_VERIFY_PARAM *param, const char *ipasc))\
  IMPORT_FUNC(unsigned long, ERR_get_error, (void))\
  IMPORT_FUNC(char *, ERR_error_string, (unsigned long e, char *buf))\
  IMPORT_FUNC(int, OBJ_sn2nid, (const char *sn))\
  IMPORT_FUNC(const char *, OBJ_nid2sn, (int n))\
  IMPORT_FUNC(int, X509_get_signature_info, (X509 *x, int *mdnid, int *pknid, int *secbits, unsigned int *flags))\
  IMPORT_FUNC(const EVP_MD *, EVP_get_digestbyname, (const char *name))\
  IMPORT_FUNC(const EVP_MD *, EVP_sha256, (void))\
  IMPORT_FUNC(int, X509_digest, (const X509 *data, const EVP_MD *type, unsigned char *md, unsigned int *len))\
  IMPORT_FUNC(void, X509_free, (X509 *a))\
  IMPORT_FUNC(int, RAND_bytes, (unsigned char *buf, int num))\
  IMPORT_FUNC(unsigned char *, SHA1, (const unsigned char *d, size_t n, unsigned char *md))

#define IMPORT_FUNC(ret, name, params) static ret (*name) params;
IMPORTED_OPEN_SSL_FUNCTIONS
#undef IMPORT_FUNC

struct ctx_password_entry {
  SSL_CTX *ctx;
  char *password;
  struct ctx_password_entry *next;
};

static struct ctx_password_entry *ctx_passwords = 0;

static int moonbit_postgres_client_tls_password_cb(
  char *buf,
  int size,
  int rwflag,
  void *userdata
) {
  (void)rwflag;
  const char *password = userdata;
  if (!password)
    return 0;

  int len = (int)strlen(password);
  if (len + 1 > size)
    return 0;

  memcpy(buf, password, len + 1);
  return len;
}

static void clear_ctx_password(SSL_CTX *ctx) {
  struct ctx_password_entry **cursor = &ctx_passwords;
  while (*cursor) {
    if ((*cursor)->ctx == ctx) {
      struct ctx_password_entry *entry = *cursor;
      *cursor = entry->next;
      free(entry->password);
      free(entry);
      SSL_CTX_set_default_passwd_cb_userdata(ctx, 0);
      return;
    }
    cursor = &(*cursor)->next;
  }
}

static int set_ctx_password(SSL_CTX *ctx, const char *password) {
  struct ctx_password_entry *entry = (struct ctx_password_entry *)malloc(sizeof(struct ctx_password_entry));
  char *copy = strdup(password);
  if (!entry || !copy) {
    free(entry);
    free(copy);
    return 0;
  }

  clear_ctx_password(ctx);

  entry->ctx = ctx;
  entry->password = copy;
  entry->next = ctx_passwords;
  ctx_passwords = entry;

  SSL_CTX_set_default_passwd_cb(ctx, moonbit_postgres_client_tls_password_cb);
  SSL_CTX_set_default_passwd_cb_userdata(ctx, copy);
  return 1;
}

int moonbit_postgres_client_tls_load_openssl(int *major, int *minor, int *fix) {
  void *handle = 0;

#ifdef __MACH__
  handle = dlopen("/usr/lib/libssl.48.dylib", RTLD_LAZY);
  if (!handle) handle = dlopen("/usr/lib/libssl.46.dylib", RTLD_LAZY);
#else
  handle = dlopen("libssl.so.3", RTLD_LAZY);
  if (!handle) handle = dlopen("libssl.so.1.1", RTLD_LAZY);
  if (!handle) handle = dlopen("libssl.so", RTLD_LAZY);
#endif
  if (!handle) return 1;

  unsigned long (*OPENSSL_version_num)() = dlsym(handle, "OpenSSL_version_num");
  if (!OPENSSL_version_num)
    return 2;

  unsigned long version = (*OPENSSL_version_num)();
  *major = version >> 28;
  *minor = (version >> 20) & 0xff;
  *fix = (version >> 12) & 0xff;

  if (*major < 1 || *major == 1 && (*minor < 1 || *minor == 1 && *fix < 1))
    return 3;

#define IMPORT_FUNC(ret, func, params)\
  func = dlsym(handle, "" #func "");\
  if (!func) return 4;

  IMPORTED_OPEN_SSL_FUNCTIONS

#undef LOAD_FUNC

  return 0;
}

void *moonbit_postgres_client_tls_bio_get_endpoint(BIO * bio) {
  void *data = BIO_get_data(bio);
  moonbit_incref(data);
  return data;
}

void moonbit_postgres_client_tls_bio_set_flags(BIO * bio, int flags) {
  return BIO_set_flags(bio, flags);
}

void moonbit_postgres_client_tls_bio_set_shutdown(BIO * bio, int flags) {
  return BIO_set_flags(bio, flags);
}

static
long dummy_bio_ctrl(BIO *bio, int cmd, long larg, void *parg) {
  if (cmd == BIO_CTRL_FLUSH) {
    // BIO_CTRL_FLUSH, this is required by SSL
    return 1;
  } else {
    return 0;
  }
}

static
int destroy_custom_bio(BIO *bio) {
  moonbit_decref(BIO_get_data(bio));
  return 1;
}

static BIO_METHOD *bio_method = 0;

void moonbit_postgres_client_tls_init_bio_method(
  int (*read)(BIO *, void *, int),
  int (*write)(BIO *, void *, int)
) {
  bio_method = BIO_meth_new(BIO_TYPE_NONE, "moonbitlang/async");
  BIO_meth_set_read(bio_method, read);
  BIO_meth_set_write(bio_method, (int (*)(BIO *, const void *, int))write);
  BIO_meth_set_ctrl(bio_method, dummy_bio_ctrl);
  BIO_meth_set_destroy(bio_method, destroy_custom_bio);
}

BIO *moonbit_postgres_client_tls_create_bio(void *data) {
  BIO *bio = BIO_new(bio_method);
  BIO_set_data(bio, data);
  BIO_set_init(bio, 1);
  return bio;
}

int moonbit_postgres_client_tls_ssl_ctx_is_null(SSL_CTX *ctx) {
  return ctx == 0;
}

SSL_CTX *moonbit_postgres_client_tls_client_ctx() {
  SSL_CTX *client_ctx = SSL_CTX_new(TLS_client_method());

  if (!client_ctx) {
    return 0;
  }
  SSL_CTX_set_verify(client_ctx, SSL_VERIFY_PEER, 0);
  SSL_CTX_ctrl(client_ctx, SSL_CTRL_MODE, SSL_MODE_ENABLE_PARTIAL_WRITE, 0);
  SSL_CTX_ctrl(client_ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, 0);
  return client_ctx;
}

SSL_CTX *moonbit_postgres_client_tls_server_ctx() {
  SSL_CTX *server_ctx = SSL_CTX_new(TLS_server_method());
  SSL_CTX_ctrl(server_ctx, SSL_CTRL_MODE, SSL_MODE_ENABLE_PARTIAL_WRITE, 0);
  return server_ctx;
}

void moonbit_postgres_client_tls_ssl_ctx_free(SSL_CTX *ctx) {
  clear_ctx_password(ctx);
  SSL_CTX_free(ctx);
}

int moonbit_postgres_client_tls_ssl_ctx_set_default_verify_paths(SSL_CTX *ctx) {
  return SSL_CTX_set_default_verify_paths(ctx);
}

int moonbit_postgres_client_tls_ssl_ctx_load_verify_file(
  SSL_CTX *ctx,
  const char *file
) {
  return SSL_CTX_load_verify_locations(ctx, file, 0);
}

int moonbit_postgres_client_tls_ssl_ctx_use_certificate_file(
  SSL_CTX *ctx,
  const char *file,
  int type
) {
  return SSL_CTX_use_certificate_file(ctx, file, type);
}

int moonbit_postgres_client_tls_ssl_ctx_use_private_key_file(
  SSL_CTX *ctx,
  const char *file,
  int type
) {
  return SSL_CTX_use_PrivateKey_file(ctx, file, type);
}

int moonbit_postgres_client_tls_ssl_ctx_set_default_password(
  SSL_CTX *ctx,
  const char *password
) {
  return set_ctx_password(ctx, password);
}

int moonbit_postgres_client_tls_ssl_ctx_check_private_key(SSL_CTX *ctx) {
  return SSL_CTX_check_private_key(ctx);
}

int moonbit_postgres_client_tls_ssl_ctx_load_crl_file(
  SSL_CTX *ctx,
  const char *file
) {
  X509_STORE *store = SSL_CTX_get_cert_store(ctx);
  if (!store)
    return 0;
  return X509_STORE_load_locations(store, file, 0);
}

int moonbit_postgres_client_tls_ssl_ctx_load_crl_dir(
  SSL_CTX *ctx,
  const char *dir
) {
  X509_STORE *store = SSL_CTX_get_cert_store(ctx);
  if (!store)
    return 0;
  return X509_STORE_load_locations(store, 0, dir);
}

int moonbit_postgres_client_tls_ssl_ctx_enable_crl_check(SSL_CTX *ctx) {
  X509_STORE *store = SSL_CTX_get_cert_store(ctx);
  if (!store)
    return 0;
  return X509_STORE_set_flags(store, X509_V_FLAG_CRL_CHECK | X509_V_FLAG_CRL_CHECK_ALL);
}

int moonbit_postgres_client_tls_ssl_ctx_set_min_protocol_version(
  SSL_CTX *ctx,
  int version
) {
  return SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, version, 0);
}

int moonbit_postgres_client_tls_ssl_ctx_set_max_protocol_version(
  SSL_CTX *ctx,
  int version
) {
  return SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, version, 0);
}

SSL *moonbit_postgres_client_tls_ssl_new(SSL_CTX *ctx, BIO *rbio, BIO *wbio) {
  SSL *ssl = SSL_new(ctx);
  if (!ssl) return ssl;

  SSL_set_bio(ssl, rbio, wbio);
  return ssl;
}

int moonbit_postgres_client_tls_ssl_connect(SSL *ssl) {
  return SSL_connect(ssl);
}

int moonbit_postgres_client_tls_ssl_set_host(SSL *ssl, const char *host) {
  return SSL_set1_host(ssl, host);
}

int moonbit_postgres_client_tls_ssl_set_ip(SSL *ssl, const char *host) {
  X509_VERIFY_PARAM *param = SSL_get0_param(ssl);
  if (!param)
    return 0;
  return X509_VERIFY_PARAM_set1_ip_asc(param, host);
}

int moonbit_postgres_client_tls_ssl_set_sni(SSL *ssl, void *host) {
  return SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, host);
}

void moonbit_postgres_client_tls_ssl_set_verify(SSL *ssl, int verify) {
  SSL_set_verify(ssl, verify ? SSL_VERIFY_PEER : SSL_VERIFY_NONE, 0);
}

int moonbit_postgres_client_tls_ssl_accept(SSL *ssl) {
  return SSL_accept(ssl);
}

int moonbit_postgres_client_tls_ssl_use_certificate_file(
  SSL *ssl,
  const char *file,
  int type
) {
  return SSL_use_certificate_file(ssl, file, type);
}

int moonbit_postgres_client_tls_ssl_use_private_key_file(
  SSL *ssl,
  const char *file,
  int type
) {
  return SSL_use_PrivateKey_file(ssl, file, type);
}

int moonbit_postgres_client_tls_ssl_read(SSL *ssl, char *buf, int offset, int num) {
  return SSL_read(ssl, buf + offset, num);
}

int moonbit_postgres_client_tls_ssl_write(SSL *ssl, char *buf, int offset, int num) {
  return SSL_write(ssl, buf + offset, num);
}

int moonbit_postgres_client_tls_ssl_shutdown(SSL *ssl) {
  return SSL_shutdown(ssl);
}

void moonbit_postgres_client_tls_ssl_free(SSL *ssl) {
  SSL_free(ssl);
}

int moonbit_postgres_client_tls_ssl_get_error(SSL *ssl, int ret) {
  return SSL_get_error(ssl, ret);
}

int moonbit_postgres_client_tls_ssl_tls_server_end_point(
  SSL *ssl,
  unsigned char *out
) {
  X509 *cert = SSL_get1_peer_certificate(ssl);
  if (!cert) {
    return 0;
  }

  int md_nid = 0;
  int pk_nid = 0;
  int secbits = 0;
  unsigned int flags = 0;
  int sha1_nid = OBJ_sn2nid("SHA1");
  int md5_nid = OBJ_sn2nid("MD5");
  const EVP_MD *digest = 0;

  if (X509_get_signature_info(cert, &md_nid, &pk_nid, &secbits, &flags)) {
    if (md_nid == md5_nid || md_nid == sha1_nid || md_nid == 0) {
      digest = EVP_sha256();
    } else {
      const char *digest_name = OBJ_nid2sn(md_nid);
      if (digest_name) {
        digest = EVP_get_digestbyname(digest_name);
      }
    }
  }
  if (!digest) {
    digest = EVP_sha256();
  }

  unsigned int len = 0;
  int ok = X509_digest(cert, digest, out, &len);
  X509_free(cert);
  if (!ok) {
    return -1;
  }
  return (int)len;
}

int moonbit_postgres_client_tls_get_error(void *buf) {
  unsigned long code = ERR_get_error();
  ERR_error_string(code, buf);
  return strlen(buf);
}

int moonbit_postgres_client_tls_rand_bytes(unsigned char *buf, int num) {
  return RAND_bytes(buf, num);
}

void moonbit_postgres_client_tls_SHA1(
  moonbit_bytes_t src,
  int32_t len,
  moonbit_bytes_t dst
) {
  SHA1(src, len, dst);
}

#endif
