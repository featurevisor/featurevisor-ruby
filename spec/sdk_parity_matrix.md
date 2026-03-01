# Ruby SDK Parity Matrix (JS Monorepo -> Ruby)

## Source of truth

- JS SDK: `monorepo/packages/sdk/src`
- JS tester: `monorepo/packages/core/src/tester`
- Types: `monorepo/packages/types/src`

## Runtime parity

- `evaluate.ts` variable override reasons
  - JS: `variable_override_rule`, `variable_override_variation`
  - Ruby: `lib/featurevisor/evaluate.rb` (`EvaluationReason`)
- `evaluate.ts` variable override index output
  - JS: `variableOverrideIndex`
  - Ruby: `variable_override_index` in evaluation payload
- `evaluate.ts` rule-level `variableOverrides` precedence
  - JS: rule `variableOverrides` before rule `variables`
  - Ruby: `lib/featurevisor/evaluate.rb` variable evaluation block
- undefined-vs-falsy checks (`typeof !== "undefined"` semantics)
  - Ruby: key-based hash checks to preserve explicit `false`/`0` values

## Tester parity

- `testProject.ts` datafile key model
  - `<environment>|false`
  - `<environment>-scope-<scope>` / `scope-<scope>`
  - `<environment>-tag-<tag>` / `tag-<tag>`
  - Ruby: `bin/commands/test.rb`
- scope fallback behavior from `testFeature.ts`
  - when not using scoped datafiles, merge scope context into assertion context
  - Ruby: `bin/commands/test.rb`
- CLI flags
  - JS: `--with-scopes`, `--with-tags`
  - Ruby: `bin/cli.rb` supports kebab-case + camelCase aliases

## Spec coverage

- `spec/evaluate_spec.rb`
  - reason constants parity
  - rule override reason/index
  - variation override reason/index
- `spec/test_command_spec.rb`
  - datafile routing precedence (scope > tag > base)
  - scope context lookup
  - scoped/tagged command generation behavior
