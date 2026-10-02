import path from 'node:path'

export const databasePath = () => path.resolve('db/eop-milky.sqlite')
export const lockPath = () => path.resolve('db/eop-milky.lock')
