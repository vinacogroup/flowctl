#!/usr/bin/env node
import { getProjectRoot, loadIndex, scoreSkill } from './skill-utils.mjs';

const args = process.argv.slice(2);
const roleIdx = args.indexOf('--role');
const tagIdx = args.indexOf('--tag');
const triggerIdx = args.indexOf('--trigger');
const limitIdx = args.indexOf('--limit');
const formatIdx = args.indexOf('--format');

const role = roleIdx >= 0 ? args[roleIdx + 1] : null;
const tag = tagIdx >= 0 ? args[tagIdx + 1] : null;
const trigger = triggerIdx >= 0 ? args[triggerIdx + 1] : null;
const limit = limitIdx >= 0 ? Number(args[limitIdx + 1]) || 5 : 5;
const format = formatIdx >= 0 ? args[formatIdx + 1] : 'table';

const consumed = new Set();
for (const idx of [roleIdx, tagIdx, triggerIdx, limitIdx, formatIdx]) {
  if (idx >= 0) {
    consumed.add(idx);
    consumed.add(idx + 1);
  }
}

const query = args.filter((_, i) => !consumed.has(i)).join(' ').trim();
const tokens = query.toLowerCase().split(/\s+/).filter(Boolean);

const projectRoot = getProjectRoot(args);
const { index } = loadIndex(projectRoot);

let skills = index.skills;
if (role) skills = skills.filter((s) => !Array.isArray(s.roles_suggested) || s.roles_suggested.length === 0 || s.roles_suggested.includes(role));
if (tag) skills = skills.filter((s) => Array.isArray(s.tags) && s.tags.includes(tag));
if (trigger) skills = skills.filter((s) => Array.isArray(s.triggers) && s.triggers.includes(trigger));

const ranked = skills
  .map((s) => ({ ...s, score: tokens.length === 0 ? 0 : scoreSkill(s, tokens, { role }) }))
  .filter((s) => tokens.length === 0 || s.score > 0)
  .sort((a, b) => b.score - a.score || a.name.localeCompare(b.name))
  .slice(0, limit);

if (format === 'json') {
  console.log(JSON.stringify(ranked, null, 2));
  process.exit(0);
}

if (ranked.length === 0) {
  console.log('No matching skills found.');
  process.exit(0);
}

for (const item of ranked) {
  const scorePart = tokens.length > 0 ? ` score=${item.score}` : '';
  console.log(`${item.name}${scorePart} - ${item.description}`);
}
