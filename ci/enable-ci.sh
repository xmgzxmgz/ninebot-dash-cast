#!/usr/bin/env bash
# 把 ci/build-ios-single.yml 装到 .github/workflows 并推送。
# 前提：当前 gh token 带 workflow 权限（gh auth refresh -h github.com -s workflow）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .github/workflows
cp ci/build-ios-single.yml .github/workflows/build-ios-single.yml
git add .github/workflows/build-ios-single.yml
git commit -m "CI: 在 macos-14 上构建 SingleCast 未签名 IPA" || true
git push
echo "已推送。去 Actions 页面看 build-ios-single 运行结果。"
