import { spawnSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'

export const DEFAULT_DB_NAME = 'moondb'
export const DEFAULT_PASSWORD = 'moonpass'
export const DEFAULT_SETUP_SQL = `
create database ${DEFAULT_DB_NAME};
set password_encryption = 'scram-sha-256';
create role moon_scram login password $$${DEFAULT_PASSWORD}$$;
set password_encryption = 'scram-sha-256';
create role moon_password login password $$${DEFAULT_PASSWORD}$$;
grant all privileges on database ${DEFAULT_DB_NAME} to moon_scram, moon_password;
`.trimStart()
export const DEFAULT_HBA_PREFIX = [
  `host    ${DEFAULT_DB_NAME}          moon_password   127.0.0.1/32            password`,
  `host    ${DEFAULT_DB_NAME}          moon_scram      127.0.0.1/32            scram-sha-256`,
  '',
].join('\n')

export function runCommand(command, args, options = {}) {
  spawnChecked(command, args, {
    cwd: options.cwd,
    env: options.env,
    input: options.input,
    stdio:
      options.stdio ??
      (options.input === undefined
        ? 'inherit'
        : ['pipe', 'inherit', 'inherit']),
  })
}

export function runCommandCapture(command, args, options = {}) {
  const result = spawnChecked(command, args, {
    cwd: options.cwd,
    env: options.env,
    input: options.input,
    stdio: options.stdio ?? ['pipe', 'pipe', 'pipe'],
  })
  return {
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
  }
}

function spawnChecked(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env,
    encoding: 'utf8',
    input: options.input,
    stdio: options.stdio,
  })
  if (result.error) {
    if (result.error.code === 'ENOENT') {
      throw new Error(`${command} is required but was not found in PATH.`)
    }
    throw result.error
  }
  if (result.status !== 0) {
    const detail = result.stderr?.trim() || result.stdout?.trim()
    const message = detail
      ? `${command} failed: ${detail}`
      : `${command} exited with status ${result.status ?? 1}`
    const error = new Error(message)
    error.exitCode = result.status ?? 1
    throw error
  }
  return result
}

export function ensureCommandAvailable(command, message) {
  const result = spawnSync(command, ['--help'], {
    stdio: 'ignore',
    env: process.env,
  })
  if (result.error?.code === 'ENOENT') {
    throw new Error(message)
  }
}

export function ensureTempPostgresPrereqs() {
  ensureCommandAvailable(
    'pg_virtualenv',
    'pg_virtualenv is required. Install postgresql-common or run tests with explicit POSTGRES_* variables.',
  )
  ensureCommandAvailable(
    'openssl',
    'openssl is required to generate temporary TLS certificates for integration tests.',
  )
}

export async function buildOuterEnv({
  repoRoot,
  tls,
  extraEnv = {},
  defaultPort = 55432,
}) {
  const port = envInt('PGPORT', defaultPort)
  const freePort = await findAvailablePort(port)
  return {
    ...process.env,
    REPO_ROOT: repoRoot,
    PGPORT: String(freePort),
    TLS_CA_CERT_FILE: tls.caCertFile,
    TLS_BAD_CA_CERT_FILE: tls.badCaCertFile,
    TLS_SERVER_CERT_FILE: tls.serverCertFile,
    TLS_SERVER_KEY_FILE: tls.serverKeyFile,
    ...extraEnv,
  }
}

export function buildInnerEnv({
  repoRoot,
  extraEnv = {},
}) {
  return {
    ...process.env,
    REPO_ROOT: process.env.REPO_ROOT ?? repoRoot,
    RUN_POSTGRES_INTEGRATION: '1',
    POSTGRES_HOST: '127.0.0.1',
    POSTGRES_PORT: requireEnv('PGPORT'),
    POSTGRES_PASSWORD: DEFAULT_PASSWORD,
    POSTGRES_DB: DEFAULT_DB_NAME,
    SSL_CERT_FILE: requireEnv('TLS_CA_CERT_FILE'),
    NODE_EXTRA_CA_CERTS: requireEnv('TLS_CA_CERT_FILE'),
    ...extraEnv,
  }
}

export function runWithPgVirtualenv({
  repoRoot,
  scriptPath,
  outerEnv,
  insideArgs = [],
}) {
  const args = [
    '-t',
    '-o',
    'ssl=on',
    '-o',
    `ssl_cert_file=${outerEnv.TLS_SERVER_CERT_FILE}`,
    '-o',
    `ssl_key_file=${outerEnv.TLS_SERVER_KEY_FILE}`,
    process.execPath,
    scriptPath,
    '--inside-pg-virtualenv',
    ...insideArgs,
  ]
  runCommand('pg_virtualenv', args, { cwd: repoRoot, env: outerEnv })
}

export function setupTemporaryCluster(
  env,
  {
    setupSql = DEFAULT_SETUP_SQL,
    hbaPrefix = DEFAULT_HBA_PREFIX,
  } = {},
) {
  configureClusterTls(env)
  runCommand('psql', ['-v', 'ON_ERROR_STOP=1', 'postgres'], {
    input: setupSql,
    env,
  })
  prependPgHba(env, hbaPrefix)
  runCommand(
    'psql',
    ['-v', 'ON_ERROR_STOP=1', 'postgres', '-c', 'select pg_reload_conf()'],
    { env },
  )
}

export function prependPgHba(env, prefix) {
  const pgHba = path.join(
    requireEnv('PG_CLUSTER_CONF_ROOT'),
    requireEnv('PGVERSION'),
    'regress',
    'pg_hba.conf',
  )
  const originalHba = fs.readFileSync(pgHba, 'utf8')
  fs.writeFileSync(pgHba, prefix + originalHba)
}

export function configureClusterTls(env) {
  const version = requireEnv('PGVERSION')
  const cluster = 'regress'
  runCommand('pg_conftool', [version, cluster, 'set', 'ssl', 'on'], { env })
  runCommand(
    'pg_conftool',
    [version, cluster, 'set', 'ssl_cert_file', requireEnv('TLS_SERVER_CERT_FILE')],
    { env },
  )
  runCommand(
    'pg_conftool',
    [version, cluster, 'set', 'ssl_key_file', requireEnv('TLS_SERVER_KEY_FILE')],
    { env },
  )
  runCommand(
    'pg_ctlcluster',
    ['--skip-systemctl-redirect', version, cluster, 'restart'],
    { env },
  )
}

export function prepareTlsAssets() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'postgres-mbt-ssl-'))
  const caKeyFile = path.join(dir, 'ca.key')
  const caCertFile = path.join(dir, 'ca.crt')
  const serverKeyFile = path.join(dir, 'server.key')
  const serverCsrFile = path.join(dir, 'server.csr')
  const serverCertFile = path.join(dir, 'server.crt')
  const serverExtFile = path.join(dir, 'server.ext')
  const badCaKeyFile = path.join(dir, 'bad-ca.key')
  const badCaCertFile = path.join(dir, 'bad-ca.crt')
  const serverCertSerial = makeCertificateSerial()
  fs.writeFileSync(
    serverExtFile,
    [
      'basicConstraints=CA:FALSE',
      'subjectAltName=IP:127.0.0.1,DNS:localhost',
      'keyUsage=digitalSignature,keyEncipherment',
      'extendedKeyUsage=serverAuth',
      '',
    ].join('\n'),
  )
  runCommand(
    'openssl',
    [
      'req',
      '-x509',
      '-new',
      '-nodes',
      '-subj',
      '/CN=postgres.mbt integration test ca',
      '-days',
      '1',
      '-sha256',
      '-keyout',
      caKeyFile,
      '-out',
      caCertFile,
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-addext',
      'keyUsage=critical,keyCertSign,cRLSign',
    ],
    { stdio: 'pipe' },
  )
  runCommand(
    'openssl',
    [
      'req',
      '-new',
      '-nodes',
      '-subj',
      '/CN=127.0.0.1',
      '-keyout',
      serverKeyFile,
      '-out',
      serverCsrFile,
      '-addext',
      'subjectAltName=IP:127.0.0.1,DNS:localhost',
    ],
    { stdio: 'pipe' },
  )
  runCommand(
    'openssl',
    [
      'x509',
      '-req',
      '-in',
      serverCsrFile,
      '-CA',
      caCertFile,
      '-CAkey',
      caKeyFile,
      '-set_serial',
      serverCertSerial,
      '-out',
      serverCertFile,
      '-days',
      '1',
      '-sha256',
      '-extfile',
      serverExtFile,
    ],
    { stdio: 'pipe' },
  )
  runCommand(
    'openssl',
    [
      'req',
      '-x509',
      '-new',
      '-nodes',
      '-subj',
      '/CN=postgres.mbt untrusted integration ca',
      '-days',
      '1',
      '-sha256',
      '-keyout',
      badCaKeyFile,
      '-out',
      badCaCertFile,
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-addext',
      'keyUsage=critical,keyCertSign,cRLSign',
    ],
    { stdio: 'pipe' },
  )
  maybeAssignToPostgres([
    dir,
    caKeyFile,
    caCertFile,
    serverKeyFile,
    serverCsrFile,
    serverCertFile,
    serverExtFile,
    badCaKeyFile,
    badCaCertFile,
  ])
  fs.chmodSync(dir, 0o700)
  fs.chmodSync(caKeyFile, 0o600)
  fs.chmodSync(caCertFile, 0o644)
  fs.chmodSync(serverKeyFile, 0o600)
  fs.chmodSync(serverCsrFile, 0o644)
  fs.chmodSync(serverCertFile, 0o644)
  fs.chmodSync(serverExtFile, 0o644)
  fs.chmodSync(badCaKeyFile, 0o600)
  fs.chmodSync(badCaCertFile, 0o644)
  return {
    dir,
    caCertFile,
    badCaCertFile,
    serverCertFile,
    serverKeyFile,
  }
}

function makeCertificateSerial() {
  const serial = randomBytes(20).toString('hex').replace(/^0+/, '')
  return `0x${serial === '' ? '1' : serial}`
}

function maybeAssignToPostgres(paths) {
  if (process.getuid?.() !== 0) {
    return
  }
  const uid = lookupAccountId('-u', 'postgres')
  const gid = lookupAccountId('-g', 'postgres')
  for (const entry of paths) {
    fs.chownSync(entry, uid, gid)
  }
}

function lookupAccountId(flag, name) {
  const result = spawnSync('id', [flag, name], {
    encoding: 'utf8',
    stdio: 'pipe',
  })
  if (result.error) {
    throw result.error
  }
  if (result.status !== 0) {
    throw new Error(`id ${flag} ${name} exited with status ${result.status ?? 1}`)
  }
  const value = Number.parseInt(result.stdout.trim(), 10)
  if (!Number.isInteger(value)) {
    throw new Error(`id ${flag} ${name} did not return an integer`)
  }
  return value
}

function requireEnv(name) {
  const value = process.env[name]
  if (value === undefined || value === '') {
    throw new Error(`Missing required environment variable: ${name}`)
  }
  return value
}

function envInt(name, defaultValue) {
  const value = process.env[name]
  if (value === undefined || value === '') {
    return defaultValue
  }
  const parsed = Number.parseInt(value, 10)
  if (!Number.isInteger(parsed)) {
    throw new Error(`Environment variable ${name} must be an integer.`)
  }
  return parsed
}

async function findAvailablePort(startPort) {
  let port = startPort
  while (!(await isPortFree(port))) {
    port += 1
  }
  return port
}

function isPortFree(port) {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.unref()
    server.once('error', (error) => {
      if (error.code === 'EADDRINUSE') {
        resolve(false)
        return
      }
      reject(error)
    })
    server.listen({ host: '127.0.0.1', port, exclusive: true }, () => {
      server.close((error) => {
        if (error) {
          reject(error)
          return
        }
        resolve(true)
      })
    })
  })
}
