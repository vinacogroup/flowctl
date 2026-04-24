#!/usr/bin/env node
import { join } from 'path';
import {
  discoverSkillFiles,
  getProjectRoot,
  readSkill,
  readPackageVersion,
  validateFrontmatter,
  writeJson,
  printIssues,
  getSkillsRoot,
} from './skill-utils.mjs';

const projectRoot = getProjectRoot();
const files = discoverSkillFiles(projectRoot);
const seenNames = new Set();
const issues = [];
const skills = [];

for (const file of files) {
  try {
    const skill = readSkill(file, projectRoot);
    const localIssues = validateFrontmatter(skill.data, file, skill.lineMap, seenNames);
    issues.push(...localIssues);

    if (localIssues.length === 0) {
      seenNames.add(skill.data.name);
      skills.push({
        name: skill.data.name,
        path: skill.relativePath,
        description: skill.data.description,
        triggers: skill.data.triggers,
        when_to_use: skill.data['when-to-use'],
        when_not_to_use: skill.data['when-not-to-use'],
        prerequisites: skill.data.prerequisites || [],
        estimated_tokens: skill.data['estimated-tokens'],
        roles_suggested: skill.data['roles-suggested'] || [],
        version: skill.data.version,
        tags: skill.data.tags || [],
      });
    }
  } catch (err) {
    issues.push({
      file,
      line: 1,
      severity: 'error',
      message: err.message,
      suggestion: 'Fix frontmatter format: must start/end with ---.',
    });
  }
}

if (issues.length > 0) {
  printIssues(issues);
  process.exit(1);
}

skills.sort((a, b) => a.name.localeCompare(b.name));

const index = {
  version: '1.0.0',
  built_at: new Date().toISOString(),
  builder_version: `flowctl ${readPackageVersion(projectRoot)}`,
  skills,
};

const outPath = join(getSkillsRoot(projectRoot), 'INDEX.json');
writeJson(outPath, index);
console.log(`INDEX built: ${outPath} (${skills.length} skills)`);
