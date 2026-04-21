const SUPPORTED_INLINE_FLAGS = new Set(["i", "m", "s", "u"])

export function compilePortableRegex(pattern: string, options: { defaultFlags?: string } = {}): RegExp {
  let source = pattern
  const flags = new Set<string>()

  for (const flag of options.defaultFlags ?? "") {
    if (!flag) continue
    flags.add(flag)
  }

  while (true) {
    const match = source.match(/^\(\?([a-z]+)\)/i)
    if (!match) break

    for (const flag of match[1]) {
      if (!SUPPORTED_INLINE_FLAGS.has(flag)) {
        throw new Error(`unsupported inline regex flag ${JSON.stringify(flag)}`)
      }
      flags.add(flag)
    }
    source = source.slice(match[0].length)
  }

  return new RegExp(source, [...flags].sort().join(""))
}
