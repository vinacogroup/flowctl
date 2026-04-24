#!/usr/bin/env node
import { join } from 'path';
import { readFileSync } from 'fs';
import { getProjectRoot, loadIndex, stripFrontmatter, appendUsageLog } from './skill-utils.mjs';

const args = process.argv.slice(2);
const formatIdx = args.indexOf('--format');
const format = formatIdx >= 0 ? args[formatIdx + 1] : 'body';

const consumed = new Set();
if (formatIdx >= 0) {
  consumed.add(formatIdx);
  consumed.add(formatIdx + 1);
}

const target = args.filter((_, i) => !consumed.has(i)).join(' ').trim();
if (!target) {
  console.error('Usage: flowctl skills load <name> [--format body|json]');
  process.exit(1);
}

const projectRoot = getProjectRoot(args);
const { index } = loadIndex(projectRoot);
const skill = index.skills.find((s) => s.name === target);

if (!skill) {
  console.error(`Skill not found: ${target}`);
  process.exit(1);
}

const absPath = join(projectRoot, '.cursor', 'skills', skill.path);
const raw = readFileSync(absPath, 'utf8');
const body = stripFrontmatter(raw).replace(/^\n+/, '');

appendUsageLog(projectRoot, {
  ts: new Date().toISOString(),
  skill: skill.name,
  version: skill.version,
  role: null,
  agent: null,
  task_id: null,
  loaded: true,
  score: null,
  tokens_loaded: skill.estimated_tokens,
  outcome: 'pending',
  relevance_feedback: null,
});

if (format === 'json') {
  console.log(JSON.stringify({ skill, body }, null, 2));
} else {
  process.stdout.write(body);
}
