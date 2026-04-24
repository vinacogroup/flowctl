#!/usr/bin/env node
import { readFileSync, readdirSync, statSync, existsSync, mkdirSync, writeFileSync, appendFileSync } from 'fs';
import { dirname, join, resolve, relative } from 'path';
import { fileURLToPath } from 'url';

const REQUIRED_FIELDS = [
  'name',
  'description',
  'triggers',
  'when-to-use',
  'when-not-to-use',
  'estimated-tokens',
  'version',
];

function stripQuotes(value) {
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    return value.slice(1, -1);
  }
  return value;
}

function parseScalar(raw) {
  const value = raw.trim();
  if (value === 'true') return true;
  if (value === 'false') return false;
  if (/^-?\d+(\.\d+)?$/.test(value)) return Number(value);
  return stripQuotes(value);
}

function parseArray(raw) {
  const value = raw.trim();
  if (!value.startsWith('[') || !value.endsWith(']')) return null;
  const inner = value.slice(1, -1).trim();
  if (!inner) return [];
  return inner.split(',').map((item) => stripQuotes(item.trim())).filter(Boolean);
}

export function parseFrontmatter(content, filePath) {
  const lines = content.split(/\r?\n/);
  if (lines[0] !== '---') {
    throw new Error(`Missing frontmatter start in ${filePath}`);
  }

  let end = -1;
  for (let i = 1; i < lines.length; i += 1) {
    if (lines[i] === '---') {
      end = i;
      break;
    }
  }
  if (end === -1) {
    throw new Error(`Missing frontmatter end in ${filePath}`);
  }

  const data = {};
  const lineMap = {};

  for (let i = 1; i < end; i += 1) {
    const line = lines[i];
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const idx = line.indexOf(':');
    if (idx <= 0) continue;

    const key = line.slice(0, idx).trim();
    const rawValue = line.slice(idx + 1).trim();
    lineMap[key] = i + 1;

    const arr = parseArray(rawValue);
    if (arr !== null) {
      data[key] = arr;
    } else {
      data[key] = parseScalar(rawValue);
    }
  }

  const body = lines.slice(end + 1).join('\n');
  return { data, body, lineMap };
}

export function validateFrontmatter(frontmatter, filePath, lineMap, seenNames = new Set()) {
  const issues = [];

  for (const field of REQUIRED_FIELDS) {
    if (!(field in frontmatter)) {
      issues.push({
        file: filePath,
        line: 1,
        severity: 'error',
        message: `Missing required field '${field}'`,
        suggestion: `Add '${field}' to frontmatter.`,
      });
    }
  }

  if (typeof frontmatter.name === 'string') {
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(frontmatter.name)) {
      issues.push({
        file: filePath,
        line: lineMap.name || 1,
        severity: 'error',
        message: `Invalid name '${frontmatter.name}' (must be kebab-case).`,
        suggestion: 'Use lowercase kebab-case, e.g. code-review.',
      });
    }
    if (seenNames.has(frontmatter.name)) {
      issues.push({
        file: filePath,
        line: lineMap.name || 1,
        severity: 'error',
        message: `Duplicate skill name '${frontmatter.name}'.`,
        suggestion: 'Use a unique skill name.',
      });
    }
  }

  if (typeof frontmatter.description !== 'string' || !frontmatter.description.trim()) {
    issues.push({
      file: filePath,
      line: lineMap.description || 1,
      severity: 'error',
      message: 'description must be a non-empty string.',
      suggestion: 'Add a one-line description (<120 chars).',
    });
  } else if (frontmatter.description.length > 120) {
    issues.push({
      file: filePath,
      line: lineMap.description || 1,
      severity: 'error',
      message: 'description must be <= 120 chars.',
      suggestion: 'Shorten the description.',
    });
  }

  if (!Array.isArray(frontmatter.triggers) || frontmatter.triggers.length < 3 || frontmatter.triggers.some((x) => typeof x !== 'string' || !x.trim())) {
    issues.push({
      file: filePath,
      line: lineMap.triggers || 1,
      severity: 'error',
      message: 'triggers must be an array of >=3 non-empty strings.',
      suggestion: 'Example: triggers: ["bug", "error", "regression"]',
    });
  }

  for (const field of ['when-to-use', 'when-not-to-use']) {
    if (typeof frontmatter[field] !== 'string' || !frontmatter[field].trim()) {
      issues.push({
        file: filePath,
        line: lineMap[field] || 1,
        severity: 'error',
        message: `${field} must be a non-empty string.`,
        suggestion: `Add a short guidance sentence for ${field}.`,
      });
    }
  }

  if (!Number.isFinite(frontmatter['estimated-tokens']) || frontmatter['estimated-tokens'] <= 0) {
    issues.push({
      file: filePath,
      line: lineMap['estimated-tokens'] || 1,
      severity: 'error',
      message: 'estimated-tokens must be a positive number.',
      suggestion: 'Estimate token count from body size (chars/4).',
    });
  }

  if (typeof frontmatter.version !== 'string' || !/^\d+\.\d+\.\d+$/.test(frontmatter.version)) {
    issues.push({
      file: filePath,
      line: lineMap.version || 1,
      severity: 'error',
      message: 'version must be semver (e.g. 1.0.0).',
      suggestion: 'Set version: "1.0.0".',
    });
  }

  for (const arrKey of ['roles-suggested', 'tags', 'prerequisites']) {
    if (arrKey in frontmatter && (!Array.isArray(frontmatter[arrKey]) || frontmatter[arrKey].some((x) => typeof x !== 'string'))) {
      issues.push({
        file: filePath,
        line: lineMap[arrKey] || 1,
        severity: 'error',
        message: `${arrKey} must be an array of strings.`,
        suggestion: `Example: ${arrKey}: ["backend", "qa"]`,
      });
    }
  }

  return issues;
}

function walk(dir, out) {
  const entries = readdirSync(dir);
  for (const entry of entries) {
    const abs = join(dir, entry);
    const st = statSync(abs);
    if (st.isDirectory()) {
      walk(abs, out);
    } else if (entry === 'SKILL.md') {
      out.push(abs);
    }
  }
}

export function getProjectRoot(args = process.argv.slice(2)) {
  const idx = args.indexOf('--project-root');
  if (idx >= 0 && args[idx + 1]) {
    return resolve(args[idx + 1]);
  }
  if (process.env.FLOWCTL_PROJECT_ROOT) {
    return resolve(process.env.FLOWCTL_PROJECT_ROOT);
  }
  return resolve(process.cwd());
}

export function getSkillsRoot(projectRoot) {
  return join(projectRoot, '.cursor', 'skills');
}

export function discoverSkillFiles(projectRoot) {
  const skillsRoot = getSkillsRoot(projectRoot);
  const files = [];

  for (const bucket of ['core', 'extended']) {
    const dir = join(skillsRoot, bucket);
    if (existsSync(dir)) {
      walk(dir, files);
    }
  }

  return files.sort();
}

export function readSkill(filePath, projectRoot) {
  const content = readFileSync(filePath, 'utf8');
  const parsed = parseFrontmatter(content, filePath);
  return {
    filePath,
    relativePath: relative(getSkillsRoot(projectRoot), filePath),
    ...parsed,
  };
}

export function ensureDir(path) {
  if (!existsSync(path)) {
    mkdirSync(path, { recursive: true });
  }
}

export function writeJson(path, data) {
  ensureDir(dirname(path));
  writeFileSync(path, `${JSON.stringify(data, null, 2)}\n`, 'utf8');
}

export function readPackageVersion(projectRoot) {
  try {
    const pkg = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'));
    return pkg.version || 'unknown';
  } catch {
    return 'unknown';
  }
}

export function loadIndex(projectRoot) {
  const indexPath = join(getSkillsRoot(projectRoot), 'INDEX.json');
  if (!existsSync(indexPath)) {
    throw new Error(`Missing ${indexPath}. Run: flowctl skills build-index`);
  }
  const index = JSON.parse(readFileSync(indexPath, 'utf8'));
  return { indexPath, index };
}

export function stripFrontmatter(content) {
  if (!content.startsWith('---\n')) return content;
  const end = content.indexOf('\n---\n', 4);
  if (end === -1) return content;
  return content.slice(end + 5);
}

export function appendUsageLog(projectRoot, payload) {
  const logPath = join(projectRoot, '.flowctl', 'skill_usage.jsonl');
  ensureDir(dirname(logPath));
  appendFileSync(logPath, `${JSON.stringify(payload)}\n`, 'utf8');
}

export function printIssues(issues) {
  for (const issue of issues) {
    const prefix = issue.severity === 'error' ? 'ERROR' : 'WARN';
    console.error(`${prefix} ${issue.file}:${issue.line} ${issue.message}`);
    if (issue.suggestion) {
      console.error(`  suggestion: ${issue.suggestion}`);
    }
  }
}

export function scoreSkill(skill, queryTokens, options = {}) {
  const q = queryTokens;
  let score = 0;
  const name = String(skill.name || '').toLowerCase();
  const desc = String(skill.description || '').toLowerCase();
  const triggers = Array.isArray(skill.triggers) ? skill.triggers.map((x) => String(x).toLowerCase()) : [];
  const tags = Array.isArray(skill.tags) ? skill.tags.map((x) => String(x).toLowerCase()) : [];
  const roles = Array.isArray(skill.roles_suggested) ? skill.roles_suggested : [];

  for (const token of q) {
    if (name === token) score += 10;
    else if (name.includes(token)) score += 6;
    if (triggers.includes(token)) score += 4;
    else if (triggers.some((t) => t.includes(token))) score += 2;
    if (desc.includes(token)) score += 1;
    if (tags.includes(token)) score += 1;
  }

  if (options.role && roles.includes(options.role)) {
    score += 2;
  }
  if (options.role && roles.length > 0 && !roles.includes(options.role)) {
    score -= 1;
  }

  return score;
}
