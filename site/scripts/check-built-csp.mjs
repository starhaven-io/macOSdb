#!/usr/bin/env node
import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';

const root = path.resolve('dist/client');
const problems = [];

function visit(directory) {
  for (const name of readdirSync(directory)) {
    const file = path.join(directory, name);
    if (statSync(file).isDirectory()) {
      visit(file);
    } else if (name.endsWith('.html')) {
      inspect(file);
    }
  }
}

function inspect(file) {
  const html = readFileSync(file, 'utf8');
  for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\b[^>]*>/gi)) {
    const attributes = match[1];
    if (/\bsrc\s*=/i.test(attributes) || /\btype\s*=\s*["']application\/ld\+json["']/i.test(attributes)) {
      continue;
    }
    problems.push(`${path.relative(root, file)}: executable inline script`);
  }
  if (/<style\b/i.test(html)) problems.push(`${path.relative(root, file)}: inline style block`);
  if (/\sstyle\s*=/i.test(html)) problems.push(`${path.relative(root, file)}: inline style attribute`);
  if (/\son[a-z]+\s*=/i.test(html)) problems.push(`${path.relative(root, file)}: inline event handler`);
}

visit(root);
if (problems.length > 0) {
  console.error('Built pages violate the deployed Content-Security-Policy:');
  for (const problem of problems.slice(0, 50)) console.error(`  - ${problem}`);
  if (problems.length > 50) console.error(`  - ${problems.length - 50} additional problem(s)`);
  process.exit(1);
}
console.log('Built HTML contains no executable inline scripts or inline styles.');
