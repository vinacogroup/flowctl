#!/usr/bin/env node
import { discoverSkillFiles, getProjectRoot, readSkill, validateFrontmatter, printIssues } from './skill-utils.mjs';

const projectRoot = getProjectRoot();
const files = discoverSkillFiles(projectRoot);
const seenNames = new Set();
const issues = [];

for (const file of files) {
  try {
    const skill = readSkill(file, projectRoot);
    const local = validateFrontmatter(skill.data, file, skill.lineMap, seenNames);
    issues.push(...local);
    if (local.length === 0) {
      seenNames.add(skill.data.name);
    }
  } catch (err) {
    issues.push({
      file,
      line: 1,
      severity: 'error',
      message: err.message,
      suggestion: 'Fix frontmatter markers and key/value syntax.',
    });
  }
}

if (issues.length > 0) {
  printIssues(issues);
  console.error(`\nLint failed: ${issues.length} issue(s)`);
  process.exit(1);
}

console.log(`Lint OK: ${files.length} skill file(s) validated`);
