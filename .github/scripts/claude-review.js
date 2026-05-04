const { execSync } = require('child_process');
const https = require('https');
const Anthropic = require('@anthropic-ai/sdk');

const MAX_DIFF_CHARS = 20000; // Trim very large PRs to avoid huge token bills

async function main() {
  const { ANTHROPIC_API_KEY, GITHUB_TOKEN, PR_NUMBER, REPO, BASE_SHA, HEAD_SHA } = process.env;

  // Get the diff
  let diff;
  try {
    diff = execSync(`git diff ${BASE_SHA}...${HEAD_SHA} -- . ':(exclude)*.lock' ':(exclude)package-lock.json'`, {
      encoding: 'utf8',
      maxBuffer: 10 * 1024 * 1024,
    });
  } catch (err) {
    console.error('Failed to get diff:', err.message);
    process.exit(1);
  }

  if (!diff.trim()) {
    console.log('No diff found, skipping review.');
    return;
  }

  if (diff.length > MAX_DIFF_CHARS) {
    diff = diff.slice(0, MAX_DIFF_CHARS) + '\n\n[Diff truncated — too large to review in full]';
  }

  // Call Claude
  const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY });

  const response = await client.messages.create({
    model: 'claude-sonnet-4-6',
    max_tokens: 1024,
    system: `You are a senior software engineer doing a code review. 
Be direct and practical. Focus on:
- Bugs or logic errors
- Security issues
- Performance problems
- Unclear or misleading code

Do NOT comment on style nitpicks, formatting, or things that are purely personal preference.
Keep your review concise. If the code looks good, say so briefly.
Use markdown in your response.`,
    messages: [
      {
        role: 'user',
        content: `Please review this pull request diff:\n\n\`\`\`diff\n${diff}\n\`\`\``,
      },
    ],
  });

  const reviewText = response.content[0].text;

  // Post comment to GitHub
  const [owner, repoName] = REPO.split('/');
  const body = JSON.stringify({
    body: `## Claude Code Review\n\n${reviewText}\n\n---\n*Reviewed by Claude (claude-sonnet-4-6)*`,
  });

  await new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: 'api.github.com',
        path: `/repos/${owner}/${repoName}/issues/${PR_NUMBER}/comments`,
        method: 'POST',
        headers: {
          Authorization: `Bearer ${GITHUB_TOKEN}`,
          'Content-Type': 'application/json',
          'User-Agent': 'claude-pr-reviewer',
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            console.log('Review posted successfully.');
            resolve();
          } else {
            reject(new Error(`GitHub API responded with ${res.statusCode}: ${data}`));
          }
        });
      }
    );

    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
