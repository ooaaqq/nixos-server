import path from 'node:path'
import { parseArgs } from 'node:util'

export function parseCLI(args: string[]) {
  const { values, positionals } = parseArgs({ args, allowPositionals: true, strict: true, options: {
    send: { type: 'boolean' }, 'dry-run': { type: 'boolean' }, once: { type: 'boolean' },
    status: { type: 'boolean' }, drain: { type: 'boolean' },
    config: { type: 'string', short: 'c' }, help: { type: 'boolean', short: 'h' },
  } })
  if (positionals.length > 1 || (positionals.length === 1 && positionals[0] !== 'run'))
    throw new Error('The only supported command is run')
  if (values.send && values['dry-run']) throw new Error('Choose either --send or --dry-run')
  if (values.status && values.drain) throw new Error('Choose either --status or --drain')
  if (values.drain && !values.send) throw new Error('--drain requires --send')
  const mode = values.send ? 'send' : 'dry-run'
  const once = mode === 'dry-run' || !!values.once || !!values.drain
  const upstreamArgs = ['run']
  if (once) upstreamArgs.push('--once')
  if (values.config) upstreamArgs.push('-c', path.relative(process.cwd(), path.resolve(values.config)))
  return { mode, once, status: !!values.status, drain: !!values.drain, help: !!values.help, upstreamArgs } as const
}
