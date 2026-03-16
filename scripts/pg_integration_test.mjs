#!/usr/bin/env node

import { spawnSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptFile = fileURLToPath(import.meta.url)
const scriptDir = path.dirname(scriptFile)
const repoRoot = path.resolve(scriptDir, '..')
const scriptPath = path.resolve(scriptFile)
const setupSql = `
create database moondb;
set password_encryption = 'scram-sha-256';
create role moon_scram login password $$moonpass$$;
set password_encryption = 'md5';
create role moon_md5 login password $$moonpass$$;
set password_encryption = 'scram-sha-256';
create role moon_password login password $$moonpass$$;
grant all privileges on database moondb to moon_scram, moon_md5, moon_password;
`.trimStart()
const hbaPrefix = [
  'host    moondb          moon_password   127.0.0.1/32            password',
  'host    moondb          moon_md5        127.0.0.1/32            md5',
  'host    moondb          moon_scram      127.0.0.1/32            scram-sha-256',
  '',
].join('\n')
const authSuites = [
  ['scram-sha-256', 'moon_scram'],
  ['md5', 'moon_md5'],
  ['password', 'moon_password'],
]
const integrationPackages = ['src/client', 'src/protocol']

main().catch((error) => {
  console.error(error.message)
  process.exit(error.exitCode ?? 1)
})

async function main() {
  if (hasFlag('--inside-pg-virtualenv')) {
    runInsideVirtualenv()
    return
  }
  await runOutsideVirtualenv()
}

async function runOutsideVirtualenv() {
  ensureCommandAvailable(
    'pg_virtualenv',
    'pg_virtualenv is required. Install postgresql-common or run tests with explicit POSTGRES_* variables.',
  )
  ensureCommandAvailable(
    'openssl',
    'openssl is required to generate temporary TLS certificates for integration tests.',
  )
  const tls = prepareTlsAssets()
  try {
    const env = await buildOuterEnv(tls)
    const args = [
      '-t',
      '-o',
      'ssl=on',
      '-o',
      `ssl_cert_file=${tls.serverCertFile}`,
      '-o',
      `ssl_key_file=${tls.serverKeyFile}`,
      process.execPath,
      scriptPath,
      '--inside-pg-virtualenv',
    ]
    if (hasFlag('--enable-coverage')) {
      args.push('--enable-coverage')
    }
    runCommand(
      'pg_virtualenv',
      args,
      { cwd: repoRoot, env },
    )
  } finally {
    fs.rmSync(tls.dir, { recursive: true, force: true })
  }
}

function runInsideVirtualenv() {
  const env = buildInnerEnv()
  const currentRepoRoot = env.REPO_ROOT
  const enableCoverage = hasFlag('--enable-coverage')
  configureClusterTls(env)
  runCommand('psql', ['-v', 'ON_ERROR_STOP=1', 'postgres'], { input: setupSql, env })

  const pgHba = path.join(
    requireEnv('PG_CLUSTER_CONF_ROOT'),
    requireEnv('PGVERSION'),
    'regress',
    'pg_hba.conf',
  )
  const originalHba = fs.readFileSync(pgHba, 'utf8')
  fs.writeFileSync(pgHba, hbaPrefix + originalHba)

  runCommand('psql', ['-v', 'ON_ERROR_STOP=1', 'postgres', '-c', 'select pg_reload_conf()'], { env })

  if (enableCoverage) {
    runCommand('moon', ['coverage', 'clean'], { cwd: currentRepoRoot, env })
  }

  for (const [authLabel, authUser] of authSuites) {
    console.log(`==> Running integration tests with ${authLabel} authentication`)
    for (const pkg of integrationPackages) {
      const moonArgs = ['test', pkg, '--filter', env.TEST_FILTER]
      if (enableCoverage) {
        moonArgs.push('--enable-coverage')
      }
      runCommand('moon', moonArgs, {
        cwd: currentRepoRoot,
        env: { ...env, POSTGRES_USER: authUser },
      })
    }
  }

  console.log('==> Running integration tests for TLS verification failures')
  const tlsFailureArgs = [
    'test',
    'src/client',
    '--filter',
    'integration tls rejects untrusted server certificate',
  ]
  runCommand('moon', tlsFailureArgs, {
    cwd: currentRepoRoot,
    env: {
      ...env,
      POSTGRES_USER: 'moon_scram',
      POSTGRES_TLS_EXPECT_FAILURE: '1',
      SSL_CERT_FILE: requireEnv('TLS_BAD_CA_CERT_FILE'),
    },
  })

  if (enableCoverage) {
    runCommand('moon', ['coverage', 'report', '--', '-f', 'caret'], {
      cwd: currentRepoRoot,
      env,
    })
  }
}

async function buildOuterEnv(tls) {
  const port = envInt('PGPORT', 55432)
  const freePort = await findAvailablePort(port)
  return {
    ...process.env,
    REPO_ROOT: repoRoot,
    PGPORT: String(freePort),
    TLS_CA_CERT_FILE: tls.caCertFile,
    TLS_BAD_CA_CERT_FILE: tls.badCaCertFile,
    TLS_SERVER_CERT_FILE: tls.serverCertFile,
    TLS_SERVER_KEY_FILE: tls.serverKeyFile,
    TEST_FILTER: process.env.TEST_FILTER ?? 'integration*',
  }
}

function configureClusterTls(env) {
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

function buildInnerEnv() {
  return {
    ...process.env,
    REPO_ROOT: process.env.REPO_ROOT ?? repoRoot,
    RUN_POSTGRES_INTEGRATION: '1',
    POSTGRES_HOST: '127.0.0.1',
    POSTGRES_PORT: requireEnv('PGPORT'),
    POSTGRES_PASSWORD: 'moonpass',
    POSTGRES_DB: 'moondb',
    SSL_CERT_FILE: requireEnv('TLS_CA_CERT_FILE'),
    NODE_EXTRA_CA_CERTS: requireEnv('TLS_CA_CERT_FILE'),
    TEST_FILTER: process.env.TEST_FILTER ?? 'integration*',
  }
}

function prepareTlsAssets() {
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

function runCommand(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env,
    encoding: 'utf8',
    input: options.input,
    stdio:
      options.stdio ??
      (options.input === undefined
        ? 'inherit'
        : ['pipe', 'inherit', 'inherit']),
  })
  if (result.error) {
    if (result.error.code === 'ENOENT') {
      throw new Error(`${command} is required but was not found in PATH.`)
    }
    throw result.error
  }
  if (result.status !== 0) {
    const detail = result.stderr?.trim()
    const message = detail
      ? `${command} failed: ${detail}`
      : `${command} exited with status ${result.status ?? 1}`
    const error = new Error(message)
    error.exitCode = result.status ?? 1
    throw error
  }
}

function ensureCommandAvailable(command, message) {
  const result = spawnSync(command, ['--help'], {
    stdio: 'ignore',
    env: process.env,
  })
  if (result.error?.code === 'ENOENT') {
    throw new Error(message)
  }
}

function hasFlag(flag) {
  return process.argv.includes(flag)
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
