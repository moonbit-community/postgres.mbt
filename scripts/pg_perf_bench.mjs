#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  buildInnerEnv,
  buildOuterEnv,
  ensureTempPostgresPrereqs,
  prepareTlsAssets,
  runCommandCapture,
  runWithPgVirtualenv,
  setupTemporaryCluster,
} from './pg_test_env.mjs'

const scriptFile = fileURLToPath(import.meta.url)
const scriptDir = path.dirname(scriptFile)
const repoRoot = path.resolve(scriptDir, '..')
const scriptPath = path.resolve(scriptFile)
const validScenarios = new Set([
  'all',
  'client-query-one',
  'client-prepared-hit',
  'pgpool-with-client',
  'pgpool-prepared-cache-hit',
  'pgpool-contention',
])
const helpText = [
  'Usage: node scripts/pg_perf_bench.mjs [options]',
  '',
  'Options:',
  '  --scenario NAME      all | client-query-one | client-prepared-hit | pgpool-with-client | pgpool-prepared-cache-hit | pgpool-contention',
  '  --iterations N       Measured iterations per scenario (default: 200)',
  '  --warmup N           Warmup iterations before measurement (default: 50)',
  '  --workers N          Concurrent workers for pgpool-contention (default: 8)',
  '  --export-json PATH   Write the benchmark JSON array to PATH',
  '  --compare PATH       Read a previous JSON export and print deltas',
  '  -h, --help           Show this message',
].join('\n')

main().catch((error) => {
  console.error(error.message)
  process.exit(error.exitCode ?? 1)
})

async function main() {
  const options = parseArgs(process.argv.slice(2))
  if (options.help) {
    console.log(helpText)
    return
  }
  if (hasFlag('--inside-pg-virtualenv')) {
    runInsideVirtualenv(options)
    return
  }
  await runOutsideVirtualenv(options)
}

async function runOutsideVirtualenv(_options) {
  ensureTempPostgresPrereqs()
  const tls = prepareTlsAssets()
  try {
    const env = await buildOuterEnv({ repoRoot, tls })
    runWithPgVirtualenv({
      repoRoot,
      scriptPath,
      outerEnv: env,
      insideArgs: process.argv.slice(2),
    })
  } finally {
    fs.rmSync(tls.dir, { recursive: true, force: true })
  }
}

function runInsideVirtualenv(options) {
  const env = buildInnerEnv({
    repoRoot,
    extraEnv: { POSTGRES_USER: 'moon_scram' },
  })
  setupTemporaryCluster(env)

  const moonArgs = [
    'run',
    '--quiet',
    '--target',
    'native',
    '--release',
    'benchmark/pg_perf',
    '--',
    '--scenario',
    options.scenario,
    '--iterations',
    String(options.iterations),
    '--warmup',
    String(options.warmup),
    '--workers',
    String(options.workers),
  ]
  const { stdout } = runCommandCapture('moon', moonArgs, {
    cwd: repoRoot,
    env,
  })
  const jsonLine = lastNonEmptyLine(stdout)
  const results = JSON.parse(jsonLine)
  printSummary(results)
  if (options.exportJson !== null) {
    const outputPath = path.resolve(repoRoot, options.exportJson)
    fs.mkdirSync(path.dirname(outputPath), { recursive: true })
    fs.writeFileSync(outputPath, `${JSON.stringify(results, null, 2)}\n`)
    console.log(`exported ${results.length} result(s) to ${outputPath}`)
  }
  if (options.compare !== null) {
    const comparePath = path.resolve(repoRoot, options.compare)
    const baseline = JSON.parse(fs.readFileSync(comparePath, 'utf8'))
    printComparison(results, baseline, comparePath)
  }
}

function parseArgs(argv) {
  const options = {
    help: false,
    scenario: 'all',
    iterations: 200,
    warmup: 50,
    workers: 8,
    exportJson: null,
    compare: null,
  }
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === '--inside-pg-virtualenv') {
      continue
    }
    if (arg === '-h' || arg === '--help') {
      options.help = true
      continue
    }
    if (arg === '--scenario') {
      options.scenario = requireNextValue(argv, index, arg)
      index += 1
      continue
    }
    if (arg === '--iterations') {
      options.iterations = parsePositiveInt(requireNextValue(argv, index, arg), arg)
      index += 1
      continue
    }
    if (arg === '--warmup') {
      options.warmup = parseNonNegativeInt(requireNextValue(argv, index, arg), arg)
      index += 1
      continue
    }
    if (arg === '--workers') {
      options.workers = parsePositiveInt(requireNextValue(argv, index, arg), arg)
      index += 1
      continue
    }
    if (arg === '--export-json') {
      options.exportJson = requireNextValue(argv, index, arg)
      index += 1
      continue
    }
    if (arg === '--compare') {
      options.compare = requireNextValue(argv, index, arg)
      index += 1
      continue
    }
    throw new Error(`unknown option: ${arg}`)
  }
  if (!validScenarios.has(options.scenario)) {
    throw new Error(`unsupported scenario: ${options.scenario}`)
  }
  return options
}

function requireNextValue(argv, index, flag) {
  const value = argv[index + 1]
  if (value === undefined) {
    throw new Error(`missing value after ${flag}`)
  }
  return value
}

function parsePositiveInt(raw, flag) {
  const value = Number.parseInt(raw, 10)
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`${flag} must be a positive integer`)
  }
  return value
}

function parseNonNegativeInt(raw, flag) {
  const value = Number.parseInt(raw, 10)
  if (!Number.isInteger(value) || value < 0) {
    throw new Error(`${flag} must be a non-negative integer`)
  }
  return value
}

function printSummary(results) {
  console.log('Scenario                      mean_us     p95_us      max_us       ops/s')
  for (const result of results) {
    console.log(
      `${result.scenario.padEnd(28)} ${formatNumber(result.mean_us).padStart(10)} ${formatNumber(result.p95_us).padStart(10)} ${formatNumber(result.max_us).padStart(10)} ${formatNumber(result.ops_per_sec).padStart(10)}`,
    )
  }
}

function printComparison(results, baseline, comparePath) {
  const baselineByScenario = new Map(baseline.map((item) => [item.scenario, item]))
  console.log(`comparison against ${comparePath}`)
  console.log('Scenario                      mean Δ        p95 Δ        ops/s Δ')
  for (const result of results) {
    const previous = baselineByScenario.get(result.scenario)
    if (!previous) {
      console.log(`${result.scenario.padEnd(28)} ${'n/a'.padStart(10)} ${'n/a'.padStart(12)} ${'n/a'.padStart(12)}`)
      continue
    }
    const meanDelta = formatPercentDelta(result.mean_us, previous.mean_us)
    const p95Delta = formatPercentDelta(result.p95_us, previous.p95_us)
    const throughputDelta = formatPercentDelta(result.ops_per_sec, previous.ops_per_sec)
    console.log(
      `${result.scenario.padEnd(28)} ${meanDelta.padStart(10)} ${p95Delta.padStart(12)} ${throughputDelta.padStart(12)}`,
    )
  }
}

function formatPercentDelta(current, previous) {
  if (previous === 0) {
    return 'n/a'
  }
  const delta = ((current - previous) / previous) * 100
  const sign = delta >= 0 ? '+' : ''
  return `${sign}${delta.toFixed(2)}%`
}

function formatNumber(value) {
  if (!Number.isFinite(value)) {
    return 'n/a'
  }
  return value.toFixed(1)
}

function lastNonEmptyLine(text) {
  const lines = text
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter((line) => line !== '')
  if (lines.length === 0) {
    throw new Error('benchmark runner did not produce JSON output')
  }
  return lines[lines.length - 1]
}

function hasFlag(flag) {
  return process.argv.includes(flag)
}
