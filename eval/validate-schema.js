#!/usr/bin/env node
/**
 * Schema validation for contentStructure documents.
 *
 * Validates any extraction output (corpus predicted.json, a bridge capture from
 * a consumer app, etc.) against shared/content-structure.schema.json — the
 * universal contract every Velo/Scribe parser must honor.
 *
 * The schema declares draft 2020-12 ($schema), so we use Ajv2020. The schema is
 * deliberately permissive about extra properties: it does NOT set
 * additionalProperties:false, so producer-private fields that aren't part of the
 * published contract (e.g. a chapter's `id`, `tokens`, `paragraphStarts`) are
 * allowed through. The fields the contract DOES name (title, plainText,
 * startPage, level, sourceType, footnotes, images, ...) are type-checked.
 * date-time formats are validated via ajv-formats.
 *
 * Usage as a module:
 *   import { validateContentStructure } from './validate-schema.js';
 *   const { valid, errors } = validateContentStructure(doc);
 *
 * Usage as a CLI (validate one or more JSON files):
 *   node eval/validate-schema.js path/to/predicted.json [more.json ...]
 */

import { readFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const SCHEMA_PATH = resolve(__dirname, '..', 'shared', 'content-structure.schema.json');

let _validator = null;

/** Compile (once) and return the ajv validate function for contentStructure. */
export function getValidator() {
  if (_validator) return _validator;
  const schema = JSON.parse(readFileSync(SCHEMA_PATH, 'utf-8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  _validator = ajv.compile(schema);
  return _validator;
}

/**
 * Validate a parsed contentStructure object.
 * @returns {{ valid: boolean, errors: string[] }} human-readable error strings.
 */
export function validateContentStructure(doc) {
  const validate = getValidator();
  const valid = validate(doc);
  if (valid) return { valid: true, errors: [] };
  const errors = (validate.errors || []).map(formatError);
  return { valid: false, errors };
}

function formatError(err) {
  const where = err.instancePath || '(root)';
  let msg = `${where} ${err.message}`;
  if (err.keyword === 'additionalProperties' && err.params?.additionalProperty) {
    msg += ` ('${err.params.additionalProperty}')`;
  }
  if (err.keyword === 'enum' && err.params?.allowedValues) {
    msg += ` [${err.params.allowedValues.join(', ')}]`;
  }
  return msg;
}

// CLI entry
if (import.meta.url === `file://${process.argv[1]}`) {
  const files = process.argv.slice(2);
  if (files.length === 0) {
    console.error('Usage: node eval/validate-schema.js <file.json> [...]');
    process.exit(2);
  }
  let anyInvalid = false;
  for (const f of files) {
    let doc;
    try {
      doc = JSON.parse(readFileSync(f, 'utf-8'));
    } catch (e) {
      console.error(`  ✗ ${f}: could not read/parse (${e.message})`);
      anyInvalid = true;
      continue;
    }
    const { valid, errors } = validateContentStructure(doc);
    if (valid) {
      console.error(`  ✓ ${f}: schema-valid`);
    } else {
      anyInvalid = true;
      console.error(`  ✗ ${f}: ${errors.length} schema violation(s)`);
      for (const e of errors.slice(0, 20)) console.error(`      ${e}`);
      if (errors.length > 20) console.error(`      … and ${errors.length - 20} more`);
    }
  }
  process.exit(anyInvalid ? 1 : 0);
}
