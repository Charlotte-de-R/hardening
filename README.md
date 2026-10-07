# コンテナセキュリティ強化リポジトリ 🛡️

`ghcr.io` に公開されるコンテナイメージのための、自動ビルドパイプラインおよびセキュリティ強化（ハーデニング）設定です。

## 📌 アーキテクチャと機能

このリポジトリは、上流アプリケーションのリリース取得、Dockerfileへのセキュリティ強化ステップの組み込み、セキュリティ強化されたコンテナイメージのビルド、Cosignによる署名、Trivyによる脆弱性スキャン、そしてGitHub Container Registry (`ghcr.io`) への公開プロセスを自動化します。

### 🔑 主な機能
* **汎用的なセキュリティ強化 (`templates/universal_hardening.txt`)**:
  - Alpine (`apk`) / Debian (`apt-get`) のOSパッケージおよびセキュリティライブラリ（例: `libssl3`、`libcrypto3`、`zlib`、`sqlite`）を自動的にアップデートします。
  - 安全ではないツール（`vim`、`nano`、`git`、`telnet`、`ftp`）を削除し、パッケージキャッシュをクリーンアップします。
  - 脆弱性のあるランタイム依存関係（Node.jsのnpm / Pythonのpipパッケージ）をアップグレードします。
  - 一時ファイルをクリーンアップし、Trivyのスキャン用にレイヤーを最適化します。
* **自動アップデート検知 (`check_update.sh`)**:
  - 上流のGitHubリリース / タグ（例: Tailscale、CrowdSec、Vaultwarden、Immich、Tetragon、Portainer、CryptPad、Nextcloud）を監視します。
  - 既存のコンテナイメージ内でOSレベルのパッケージアップデートが保留されていないか確認します。
* **GitHub Actions CI/CD パイプライン (`scheduled-harden.yml`)**:
  - Docker Buildxのマトリックス戦略を使用して、毎日定期実行されるビルドを実行します。
  - GitHub Actionsキャッシュ（`type=gha`）によりビルド速度を高速化します。
  - **Cosign** のキーレスOIDC署名でイメージに署名します。
  - **Trivy** を使用してイメージの `CRITICAL`（致命的）な脆弱性をスキャンし、SARIFレポートをGitHubのSecurity Code Scanningタブにアップロードします。

---

## 📁 リポジトリ構造

```text
.
├── .github/workflows/
│   └── scheduled-harden.yml    # 自動ビルド、スキャン、署名、公開を行うGitHub Actionsワークフロー
├── templates/
│   └── universal_hardening.txt # Dockerfileに挿入される汎用的なセキュリティ強化スニペット
├── dockerfiles/
│   ├── crowdsec/
│   ├── cryptpad/
│   ├── immich-machine-learning/
│   ├── immich-postgres/
│   ├── immich-redis/
│   ├── immich-server/
│   ├── mariadb/
│   ├── nextcloud/
│   ├── portainer/
│   ├── promtail/
│   ├── socket-proxy/
│   ├── tailscale/
│   ├── tetragon/
│   └── vaultwarden/
├── check_update.sh             # 上流のリリースおよびOSのアップデート確認スクリプト
├── update_dockerfiles.sh       # universal_hardening.txtをDockerfileに挿入するスクリプトスコプト
└── README.md
```

---

## 🛠️ 使い方と運用

### 1. すべてのDockerfileにおけるセキュリティ強化テンプレートの更新
`templates/universal_hardening.txt` に変更を加えた場合は、以下を実行します：

```bash
chmod +x update_dockerfiles.sh
./update_dockerfiles.sh
```

これにより、対象となるすべての `Dockerfile.hardened` ファイル内の `# --- COMMON HARDENING START ---` から `# --- COMMON HARDENING END ---` までのブロックが置き換えられます。

### 2. イメージのアップデート状態の確認
特定のイメージに上流のバージョンやOSパッケージのアップデートが必要かどうかを確認するには、以下を実行します：

```bash
chmod +x check_update.sh
./check_update.sh ghcr.io/charlotte-de-r/hardening/vaultwarden:hardened
```

### 3. ワークフローの手動トリガー
GitHub Actionsタブからワークフローを手動でトリガーできます（`workflow_dispatch`）。`force_build: true` を有効にすると、アップデートの検知状況に関係なく、すべてのコンテナイメージが強制的に再ビルドされます。
