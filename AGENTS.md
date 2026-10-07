# AGENTS.md — Container Hardening Repository (`Charlotte-de-R/hardening`)

このリポジトリは、Kali Purple 上で稼働するゼロトラスト・サーバー向けの堅牢化（Hardened）コンテナイメージを自動ビルドし、脆弱性検査（Trivy）および電子署名（Cosign）を施して GitHub Container Registry (`ghcr.io`) へ公開する CI パイプラインです。

AI エージェント（Jules 等）は、本ガイドラインに従って設計思想を損なわずに保守・改修を行ってください。

---

## 1. リポジトリ構成と役割

```
.
├── .github/workflows/
│   └── scheduled-harden.yml       # 定期ビルド、Trivyスキャン、Cosign署名CI
├── templates/
│   └── universal_hardening.txt    # 共通堅牢化スクリプト（Alpine/Debian OS更新、不要ツール削除）
├── dockerfiles/
│   ├── crowdsec/
│   ├── cryptpad/
│   ├── immich-machine-learning/   # Python 仮想環境 (/opt/venv)
│   ├── immich-postgres/
│   ├── immich-redis/
│   ├── immich-server/             # Node.js (pnpm) + C++ 画像ライブラリ
│   ├── mariadb/
│   ├── nextcloud/                 # sid 更新除外（Apache MPM 競合対策）
│   ├── portainer/                 # Go アプリ再ビルド + Docker CLI 更新
│   ├── promtail/
│   ├── socket-proxy/
│   ├── tailscale/
│   ├── tetragon/
│   └── vaultwarden/               # Rust バイナリ + DBクライアント
├── check_update.sh                # 上流 GitHub リリース & OS 更新検知スクリプト
└── update_dockerfiles.sh          # 共通テンプレートを各 Dockerfile.hardened に注入
```

---

## 2. 開発・改修ルール

### ルール 1: 共通テンプレートの変更と同期
* OS パッケージの更新ルールや不要ツールの削除ルールを変更する場合、**`templates/universal_hardening.txt`** を編集してください。
* 編集後は **必ず `./update_dockerfiles.sh` を実行** して各 `Dockerfile.hardened` に反映してください。
* 各 `Dockerfile.hardened` 内の `# --- COMMON HARDENING START ---` から `# --- COMMON HARDENING END ---` の間を手動で直接編集してはいけません（上書きされます）。

### ルール 2: アプリケーション固有の CVE 対策方針
各コンテナの言語スタックに応じた適切なアプローチをとること:

1. **Node.js / pnpm（`immich-server` 等）**:
   - pnpm の仮想ストア構造（`.pnpm`）やロックファイルの競合を壊さないため、ライブラリの脆弱性修正には **外科的置換（Surgical Strike パッチ）** を採用します。
   - 一時ディレクトリ（`/tmp/patch`）で `npm install <pkg>@<safe_version>` を行い、対象ディレクトリを上書き配置します。
2. **Python 仮想環境（`immich-machine-learning` 等）**:
   - Python パッケージは `/opt/venv` にインストールされているため、ホストの pip ではなく `/opt/venv/bin/pip install --upgrade <pkg>` を明示的に呼び出してください。
3. **Go バイナリ（`portainer` 等）**:
   - `go get <module>@<safe_version> && go mod tidy` で依存関係を更新し、マルチステージビルドで静的バイナリを再生成します。
4. **Nextcloud**:
   - Nextcloud は Debian sid のパッケージ（特に Apache MPM / PHP 関連）を取り込むと起動時に exit 137 (SIGKILL) でクラッシュするため、`universal_hardening.txt` の自動注入対象から除外されています。個別の apt-get upgrade で対応してください。

### ルール 3: CI/CD・サプライチェーンセキュリティ方針
`.github/workflows/scheduled-harden.yml` を編集する際の重要原則:

1. **信頼チェーンの整合性**:
   - 原則として「ビルド → Trivy スキャン合格 → 署名（Cosign）→ 公開」の順序を守ること。
   - スキャンに失敗したイメージに署名を付与してはなりません。
2. **GitHub Actions の固定**:
   - `uses: actions/checkout@...` などのサードパーティ Actions は、タグ（`@master`, `@v1` 等）ではなく **40 桁の完全コミット SHA** でピン留めしてください。
3. **権限の最小化**:
   - ワークフローの `permissions` は必要最小限（`packages: write`, `id-token: write`, `security-events: write`, `contents: read`）に留めること。

---

## 3. セットアップ・検証手順

環境設定スクリプト（Jules setup script）およびローカル検証:

```bash
# 1. 実行権限の付与
chmod +x update_dockerfiles.sh check_update.sh

# 2. テンプレート展開の整合性テスト
./update_dockerfiles.sh

# 3. 差分の確認
git status
git diff

# 4. （任意）特定イメージのローカルビルドテスト
docker build --no-cache \
  -t test-image:hardened \
  -f dockerfiles/vaultwarden/Dockerfile.hardened \
  dockerfiles/vaultwarden
```

---

## 4. Trivy 脆弱性判定（トリアージ方針）

GitHub Code Scanning で検出されるアラートの判断基準:

* **コンテナ環境での非該当・誤検知**:
  - `kernel: ...`（コンテナはホスト Linux カーネルを共有するため非該当）
  - `mariadb: ...` サーバー脆弱性がクライアントライブラリ（`libmariadb3`）に誤認検出されるケース（Vaultwarden などサーバー未稼働の場合）
  → これらはコードを無理に変更せず、GitHub 上で **`False positive` / `Won't fix`** としてトリアージする。
* **修正対象**:
  - アプリケーションが直接呼び出している言語ランタイムライブラリ（npm, pip, Go）
  - OS の共有ライブラリでディストリビューション側から修正版が提供されているもの
