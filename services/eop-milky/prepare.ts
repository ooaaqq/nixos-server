import { cpSync, mkdirSync, existsSync } from 'node:fs'
import path from 'node:path'

const root = path.resolve(import.meta.dir, '..')
const [source, destination] = process.argv.slice(2)
if (!source || !destination) throw new Error('Usage: bun scripts/prepare.ts UPSTREAM_APP OUTPUT_APP')
const input = path.resolve(source), output = path.resolve(destination)
if (output !== input && output.startsWith(input + path.sep))
  throw new Error('Output must be outside the upstream source directory')
const integrity = await Bun.file(path.join(root, 'upstream-integrity.json')).json() as Record<string, string>
const sourceFiles = Array.from(new Bun.Glob('src/**/*').scanSync({ cwd: input, onlyFiles: true })).sort()
const expectedFiles = Object.keys(integrity).filter(file => file.startsWith('src/')).sort()
if (JSON.stringify(sourceFiles) !== JSON.stringify(expectedFiles))
  throw new Error('Upstream source file set differs from the reviewed pin')
for (const [file, expected] of Object.entries(integrity)) {
  const hash = new Bun.CryptoHasher('sha256').update(await Bun.file(path.join(input, file)).arrayBuffer()).digest('hex')
  if (hash !== expected) throw new Error(`Unreviewed upstream file: ${file}; review the source pin and integration first`)
}
if (input !== output) {
  if (existsSync(output)) throw new Error('Output already exists; use a fresh staging directory')
  cpSync(input, output, { recursive: true })
}
const patch = Bun.spawnSync(['patch', '--batch', '--forward', '-p1', '-i', path.join(root, 'patches/eop-milky.patch')], { cwd: output })
if (patch.exitCode !== 0) throw new Error('EoP integration patch failed')
mkdirSync(path.join(output, 'src/compat'), { recursive: true })
cpSync(path.join(root, 'compat'), path.join(output, 'src/compat'), { recursive: true })
console.log(`Prepared complete EoP with Milky sender at ${output}`)
