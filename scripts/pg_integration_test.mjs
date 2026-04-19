#!/usr/bin/env node

/**
 * PostgreSQL integration test runner.
 *
 * Environment variables that change this script's behavior:
 *
 * - `PGPORT`
 *   Preferred port for the temporary PostgreSQL cluster. Defaults to `55432`.
 *   If that port is already in use, the script probes upward until it finds a
 *   free port.
 *
 * - `TEST_FILTER`
 *   Filter passed to `moon test --filter`. Defaults to `integration*`.
 *
 * - `REPO_ROOT`
 *   Repository root used when invoking `moon` commands from the inner
 *   `--inside-pg-virtualenv` phase. The outer phase sets this automatically to
 *   the current repository root, so overriding it is mainly useful when
 *   debugging the inner phase directly.
 */

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  buildInnerEnv,
  buildOuterEnv,
  ensureTempPostgresPrereqs,
  prepareTlsAssets,
  runCommand,
  runWithPgVirtualenv,
  setupTemporaryCluster,
} from './pg_test_env.mjs'

const scriptFile = fileURLToPath(import.meta.url)
const scriptDir = path.dirname(scriptFile)
const repoRoot = path.resolve(scriptDir, '..')
const scriptPath = path.resolve(scriptFile)
const authSuites = [
  ['scram-sha-256', 'moon_scram'],
  ['password', 'moon_password'],
]
const integrationPackages = ['tests/baseline']

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
  ensureTempPostgresPrereqs()
  const tls = prepareTlsAssets()
  try {
    const env = await buildOuterEnv({
      repoRoot,
      tls,
      extraEnv: {
        TEST_FILTER: process.env.TEST_FILTER ?? 'integration*',
      },
    })
    const insideArgs = []
    if (hasFlag('--enable-coverage')) {
      insideArgs.push('--enable-coverage')
    }
    runWithPgVirtualenv({
      repoRoot,
      scriptPath,
      outerEnv: env,
      insideArgs,
    })
  } finally {
    fs.rmSync(tls.dir, { recursive: true, force: true })
  }
}

function runInsideVirtualenv() {
  const env = buildInnerEnv({
    repoRoot,
    extraEnv: {
      TEST_FILTER: process.env.TEST_FILTER ?? 'integration*',
    },
  })
  const enableCoverage = hasFlag('--enable-coverage')
  setupTemporaryCluster(env)

  if (enableCoverage) {
    runCommand('moon', ['coverage', 'clean'], { cwd: repoRoot, env })
  }

  for (const [authLabel, authUser] of authSuites) {
    console.log(`==> Running integration tests with ${authLabel} authentication`)
    for (const pkg of integrationPackages) {
      const moonArgs = ['test', pkg, '--filter', env.TEST_FILTER]
      if (enableCoverage) {
        moonArgs.push('--enable-coverage')
      }
      runCommand('moon', moonArgs, {
        cwd: repoRoot,
        env: { ...env, POSTGRES_USER: authUser },
      })
    }
  }

  console.log('==> Running integration tests for TLS verification failures')
  runCommand(
    'moon',
    ['test', '--filter', 'integration tls rejects untrusted server certificate'],
    {
      cwd: repoRoot,
      env: {
        ...env,
        POSTGRES_USER: 'moon_scram',
        POSTGRES_TLS_EXPECT_FAILURE: '1',
        SSL_CERT_FILE: process.env.TLS_BAD_CA_CERT_FILE,
      },
    },
  )

  if (enableCoverage) {
    runCommand('moon', ['coverage', 'report', '--', '-f', 'caret'], {
      cwd: repoRoot,
      env,
    })
  }
}

function hasFlag(flag) {
  return process.argv.includes(flag)
}
