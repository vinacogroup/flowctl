#!/usr/bin/env node
import { getProjectRoot, loadIndex } from './skill-utils.mjs';

const args = process.argv.slice(2);
const roleIdx = args.indexOf('--role');
const tagIdx = args.indexOf('--tag');
const triggerIdx = args.indexOf('--trigger');
const formatIdx = args.indexOf('--format');

const role = roleIdx >= 0 ? args[roleIdx + 1] : null;
const tag = tagIdx >= 0 ? args[tagIdx + 1] : null;
const trigger = triggerIdx >= 0 ? args[triggerIdx + 1] : null;
const format = formatIdx >= 0 ? args[formatIdx + 1] : 'table';

const projectRoot = getProjectRoot(args);
const { index } = loadIndex(projectRoot);

let skills = [...index.skills].sort((a, b) => a.name.localeCompare(b.name));
if (role) skills = skills.filter((s) => !Array.isArray(s.roles_suggested) || s.roles_suggested.length === 0 || s.roles_suggested.includes(role));
if (tag) skills = skills.filter((s) => Array.isArray(s.tags) && s.tags.includes(tag));
if (trigger) skills = skills.filter((s) => Array.isArray(s.triggers) && s.triggers.includes(trigger));

if (format === 'json') {
  console.log(JSON.stringify(skills, null, 2));
  process.exit(0);
}

if (skills.length === 0) {
  console.log('No skills found.');
  process.exit(0);
}

for (const skill of skills) {
  console.log(`${skill.name} - ${skill.description}`);
}
