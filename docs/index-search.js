const fs = require('fs');
const path = require('path');
const { MeiliSearch } = require('meilisearch');

const MEILISEARCH_HOST = process.env.MEILISEARCH_HOST || 'http://127.0.0.1:7700';
const MEILISEARCH_KEY = process.env.MEILISEARCH_KEY || '';
const DIST_DIR = process.env.DIST_DIR || '/app/dist';
const DOCS_JSON = process.env.DOCS_JSON || '/app/docs.json';
const INDEX_NAME = 'docs';

const EXCLUDED_PREFIXES = [];

function findPages(dir, files = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === '_next') continue;
      findPages(fullPath, files);
    } else if (entry.name === 'index.html') {
      files.push(fullPath);
    }
  }
  return files;
}

function decodeEntities(text) {
  return text
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&nbsp;/g, ' ');
}

function stripTags(html) {
  return decodeEntities(
    html
      .replace(/<script[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style[\s\S]*?<\/style>/gi, ' ')
      .replace(/<[^>]+>/g, ' ')
  )
    .replace(/\s+/g, ' ')
    .trim();
}

function siteName() {
  try {
    return JSON.parse(fs.readFileSync(DOCS_JSON, 'utf8')).name || '';
  } catch (err) {
    return '';
  }
}

function extract(filePath, suffix) {
  const html = fs.readFileSync(filePath, 'utf8');
  if (html.includes('http-equiv="refresh"')) return null;

  const titleMatch = html.match(/<title>([^<]*)<\/title>/);
  let title = titleMatch ? decodeEntities(titleMatch[1]).trim() : '';
  if (suffix && title.endsWith(suffix)) {
    title = title.slice(0, -suffix.length).replace(/\s*-\s*$/, '').trim();
  }

  const descMatch = html.match(/<meta name="description" content="([^"]*)"/);
  const description = descMatch ? decodeEntities(descMatch[1]).trim() : '';

  const mainStart = html.indexOf('<main');
  const mainEnd = html.lastIndexOf('</main>');
  let content = '';
  if (mainStart >= 0 && mainEnd > mainStart) {
    content = stripTags(html.slice(mainStart, mainEnd));
  }

  return { title, description, content };
}

async function indexDocs() {
  console.log('Connecting to Meilisearch at', MEILISEARCH_HOST);

  const client = new MeiliSearch({
    host: MEILISEARCH_HOST,
    apiKey: MEILISEARCH_KEY,
  });

  const name = siteName();
  const suffix = name ? `- ${name}` : '';
  const pages = findPages(DIST_DIR);
  console.log(`Found ${pages.length} exported pages`);

  const documents = [];

  for (const filePath of pages) {
    const rel = path.relative(DIST_DIR, path.dirname(filePath));
    const slug = rel === '' || rel === '.' ? '' : rel.split(path.sep).join('/');
    if (EXCLUDED_PREFIXES.some((p) => slug.startsWith(p))) continue;

    try {
      const data = extract(filePath, suffix);
      if (!data || !data.title) continue;

      documents.push({
        id: (slug || 'index').replace(/[^a-zA-Z0-9_-]/g, '-'),
        slug: '/' + slug,
        title: data.title,
        description: data.description,
        content: data.content.substring(0, 10000),
      });
    } catch (err) {
      console.error(`Error processing ${filePath}:`, err.message);
    }
  }

  console.log(`Indexing ${documents.length} documents...`);

  const index = client.index(INDEX_NAME);

  await index.updateSettings({
    searchableAttributes: ['title', 'description', 'content'],
    displayedAttributes: ['slug', 'title', 'description'],
  });

  const task = await index.addDocuments(documents);
  console.log('Indexing task:', task.taskUid);

  await client.waitForTask(task.taskUid);
  console.log('Indexing complete!');
}

indexDocs().catch((err) => {
  console.error('Indexing failed:', err.message);
  process.exit(1);
});
