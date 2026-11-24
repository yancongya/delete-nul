import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const landingDir = resolve(__dirname, '..');
const outDir = join(landingDir, 'dist-xhs');
const zipOut = join(landingDir, 'landing-minitool.zip');
const reportOut = join(landingDir, 'landing-minitool.report.json');

console.log('🚀 开始测试 delete-nul 落地页的小红书打包兼容性...');

// 1. Vite Build with base: './'
console.log('\n📦 [步骤 1/4] 执行 Vite 构建 (base: ./, outDir: dist-xhs)...');
if (existsSync(outDir)) {
  rmSync(outDir, { recursive: true, force: true });
}

const buildRes = spawnSync('npx.cmd', ['vite', 'build', '--base', './', '--outDir', 'dist-xhs'], {
  cwd: landingDir,
  encoding: 'utf8',
  shell: true
});

if (buildRes.status !== 0) {
  console.error('❌ Vite 构建失败:\n', buildRes.stderr || buildRes.stdout);
  process.exit(1);
}
console.log('✅ Vite 构建成功。');

// 2. Transform dist-xhs to satisfy Xiaohongshu container specification
console.log('\n⚙️ [步骤 2/4] 适配小红书容器规范 (CSP, Classic Script, Compat)...');
const indexPath = join(outDir, 'index.html');
let html = readFileSync(indexPath, 'utf8');

// 2.1 Remove modulepreload
html = html.replace(/<link\s+rel=["']modulepreload["'][^>]*>/gi, '');

// 2.2 Remove target="_blank"
html = html.replace(/\s+target=["']_blank["']/gi, '');

// 2.3 Remove a[download]
html = html.replace(/\s+download\b/gi, '');

// 2.4 Extract inline scripts into assets/landing-inline.js
const inlineScripts = [];
html = html.replace(/<script(?![^>]*\bsrc)[^>]*>([\s\S]*?)<\/script>/gi, (match, code) => {
  if (code.trim()) {
    inlineScripts.push(code.trim());
  }
  return '';
});

mkdirSync(join(outDir, 'assets'), { recursive: true });
const inlineJsPath = join(outDir, 'assets', 'landing-inline.js');
writeFileSync(inlineJsPath, inlineScripts.join('\n;\n'), 'utf8');

// 2.5 Create compat.js for Chrome 61 globalThis polyfill
const compatJsPath = join(outDir, 'compat.js');
const compatCode = `// Chrome 61 compatibility polyfill
(function(w){
  if (typeof w.globalThis === 'undefined') {
    w.globalThis = w;
  }
})(typeof window !== 'undefined' ? window : this);
`;
writeFileSync(compatJsPath, compatCode, 'utf8');

// 2.6 Rewrite script tags to classic scripts with compat.js first
// Remove type="module" and crossorigin
html = html.replace(/<script\s+type=["']module["']/gi, '<script defer');
html = html.replace(/\s+crossorigin\b(=["'][^"']*["'])?/gi, '');

// Insert compat.js at top of head, and inline script before body closing
html = html.replace(/<head>/i, '<head>\n<script src="./compat.js"></script>');
html = html.replace(/<\/body>/i, '<script defer src="./assets/landing-inline.js"></script>\n</body>');

// 2.7 Ensure all asset references are relative
html = html.replace(/(?:src|href)=["']\/(?:delete-nul\/)?assets\//gi, 'src="./assets/');

writeFileSync(indexPath, html, 'utf8');
console.log('✅ 容器规范适配处理完毕。');

// 3. Run pack.py static gate check
console.log('\n🔍 [步骤 3/4] 运行 pack.py 静态门禁检测...');
const packPyPath = 'C:\\Users\\Administrator\\.skillshub\\xhs-pack\\scripts\\pack.py';

const packRes = spawnSync('python', [packPyPath, outDir, '--out', zipOut, '--report', reportOut], {
  encoding: 'utf8',
  shell: true
});

console.log(packRes.stdout.trim());
if (packRes.stderr.trim()) {
  console.log('stderr:', packRes.stderr.trim());
}

// 4. Analyze report
console.log('\n📊 [步骤 4/4] 分析门禁报告...');
if (existsSync(reportOut)) {
  const report = JSON.parse(readFileSync(reportOut, 'utf8'));
  console.log('\n========== 打包测试结果汇报 ==========');
  console.log(`产物包体: ${report.package} (${report.size_MiB} MiB)`);
  console.log(`错误数量: ${report.errors.length}`);
  console.log(`警告数量: ${report.warnings.length}`);
  if (report.errors.length > 0) {
    console.log('\n❌ 剩余错误:');
    report.errors.forEach(e => console.log('  -', e));
  } else {
    console.log('\n🎉 恭喜！静态门禁 0 错误完全通过！');
  }
  if (report.warnings.length > 0) {
    console.log('\n⚠️ 警告详情 (启发式提示):');
    report.warnings.forEach(w => console.log('  -', w));
  }
  console.log('====================================\n');
} else {
  console.error('❌ 未能生成报告文件。');
}
