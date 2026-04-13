#!/usr/bin/env bash
# sync-pack.sh — 打包项目用于跨机器同步
# 排除 .git 目录、所有编译产物、运行时数据，保持压缩包轻量
# 用法: ./sync-pack.sh [输出文件名]

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
OUTPUT="${1:-${PROJECT_NAME}-$(date +%Y%m%d-%H%M%S).tar.gz}"

# 如果输出路径是相对路径，放到项目父目录
case "$OUTPUT" in
  /*) ;; # 绝对路径，不动
  *)  OUTPUT="$(dirname "$PROJECT_DIR")/$OUTPUT" ;;
esac

cd "$(dirname "$PROJECT_DIR")"

tar czf "$OUTPUT" \
  --exclude='.git' \
  --exclude='.DS_Store' \
  --exclude='*.pyc' \
  --exclude='__pycache__' \
  \
  --exclude="$PROJECT_NAME/macos/CopyEverywhere/.build" \
  --exclude="$PROJECT_NAME/macos/CopyEverywhere/.swiftpm" \
  \
  --exclude="$PROJECT_NAME/android/.gradle" \
  --exclude="$PROJECT_NAME/android/build" \
  --exclude="$PROJECT_NAME/android/app/build" \
  --exclude="$PROJECT_NAME/android/local.properties" \
  \
  --exclude="$PROJECT_NAME/windows/CopyEverywhere/bin" \
  --exclude="$PROJECT_NAME/windows/CopyEverywhere/obj" \
  \
  --exclude="$PROJECT_NAME/server/data" \
  --exclude="$PROJECT_NAME/server/copyeverywhere-server" \
  --exclude="$PROJECT_NAME/server/copyeverywhere-server.exe" \
  \
  --exclude="$PROJECT_NAME/progress.txt" \
  --exclude="$PROJECT_NAME/archive" \
  --exclude="$PROJECT_NAME/.claude/settings.local.json" \
  \
  "$PROJECT_NAME"

SIZE=$(du -sh "$OUTPUT" | cut -f1)
echo "✓ 打包完成: $OUTPUT ($SIZE)"
echo "  在目标机器上解压: tar xzf $(basename "$OUTPUT")"
