// Keep the watchdog outside MoonBit's event loop: a regressed synchronous
// SCRAM loop or protected socket cleanup must not hang the test runner.
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const repoRoot = fileURLToPath(new URL('..', import.meta.url))
const regressions = [
  'pgpool/recycle_cancel_wbtest.mbt',
  'pgpool/config_wbtest.mbt',
  'pgpool/copy_resource_wbtest.mbt',
  'client/backend_read_wbtest.mbt',
  'client/copy_resource_wbtest.mbt',
  'client/copy_wbtest.mbt',
  'client/scoped_api_wbtest.mbt',
  'client/connection_cancel_wbtest.mbt',
  'client/scram_budget_wbtest.mbt',
  'pgpool/stream_cancel_wbtest.mbt',
  'protocol/message/backend',
  'protocol/authentication',
]

try {
  for (const target of ['native', 'wasm']) {
    console.log(`Running ${target} resource safety regressions (90s watchdog)`)
    await runTests(target)
  }
} catch (error) {
  console.error(error.message)
  process.exitCode = 1
}

function runTests(target) {
  return new Promise((resolve, reject) => {
    const child = spawn('moon', ['test', ...regressions, '--target', target], {
      cwd: repoRoot,
      stdio: 'inherit',
      detached: process.platform !== 'win32',
    })
    let timedOut = false
    const watchdog = setTimeout(() => {
      timedOut = true
      // Kill moon and its native/wasm test subprocesses together on POSIX.
      try {
        if (process.platform === 'win32') {
          child.kill('SIGKILL')
        } else {
          process.kill(-child.pid, 'SIGKILL')
        }
      } catch (error) {
        if (error.code !== 'ESRCH') reject(error)
      }
    }, 90_000)
    child.once('error', (error) => {
      clearTimeout(watchdog)
      reject(error)
    })
    child.once('close', (code, signal) => {
      clearTimeout(watchdog)
      if (timedOut) {
        reject(new Error(`${target} resource safety tests exceeded 90 seconds`))
      } else if (code !== 0) {
        reject(new Error(`${target} tests failed (${signal ?? code})`))
      } else {
        resolve()
      }
    })
  })
}
