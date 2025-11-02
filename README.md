# Kustomize Edit

Updates kustomize overlays with new image tags, labels, and annotations.

## Features

- 🏷️ **Image updates** - Set new image tags
- 📝 **Label management** - Add/update labels
- 🔖 **Annotations** - Set deployment metadata
- 📅 **Automatic timestamps** - Track deployment times
- 🎯 **Smart detection** - Handles various kustomize patterns
- 📄 **Environment file patching** - Update .env files for ConfigMap generation

## Usage

### Single image (recommended - separate image and tag)
```yaml
- name: Update kustomize overlay
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/production
    image: backend
    tag: v1.2.3
```

### Single image (backwards compatible - image:tag format)
```yaml
- name: Update kustomize overlay
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/production
    image: backend:v1.2.3
```

### Multiple images
```yaml
- name: Update multiple images
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/production
    images_json: |
      [
        {"name": "backend", "newTag": "v1.2.3"},
        {"name": "backend-migrator", "newTag": "v1.2.3"}
      ]
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `overlay_dir` | Path to kustomize overlay | ✅ | - |
| `debug` | Enable debug output | ❌ | `false` |
| `image` | Container image name | ❌* | - |
| `tag` | Image tag | ❌* | - |
| `images_json` | Multiple images as JSON array | ❌* | - |
| `version_label` | Value for app.kubernetes.io/version label | ❌ | - |
| `annotations` | Annotations to add (key:value or key=value format, one per line) | ❌ | - |
| `labels` | Labels to add (key:value or key=value format, one per line) | ❌ | - |
| `replicas` | Replicas count to set (JSON format) | ❌ | - |
| `env_patches` | Environment file patches (JSON format) | ❌ | - |
| `namespace` | Set namespace | ❌ | - |
| `name_prefix` | Add name prefix | ❌ | - |
| `name_suffix` | Add name suffix | ❌ | - |

\* **Image input options** (choose one):
  - Option 1: `image` (with embedded tag, e.g., `registry.io/app:v1.2.3`)
  - Option 2: `image` + `tag` (separate, e.g., `image: registry.io/app`, `tag: v1.2.3`)
  - Option 3: `images_json` (for multiple images)

## Outputs

| Output | Description |
|--------|-------------|
| `overlay_dir` | Path to the edited overlay |
| `kustomization_file` | Path to kustomization.yaml |

## Examples

### Basic image update
```yaml
- name: Update image tag
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/staging
    image: myapp
    tag: ${{ github.sha }}
```

### With labels and annotations
```yaml
- name: Full update
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/production
    image: backend
    tag: v2.0.0
    labels: |
      version:v2.0.0
      environment:production
      team:platform
    annotations: |
      deployed-by:${{ github.actor }}
      deployment-id:${{ github.run_id }}
    # Both key:value and key=value formats are supported
```

### With debug output
```yaml
- name: Update with debugging
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/staging
    image: api
    tag: latest
    debug: 'true'  # Shows final kustomization.yaml
```

### Patch environment files (Recommended)
```yaml
- name: Deploy with runtime configuration
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/production
    image: backend
    tag: ${{ github.sha }}
    env_patches: |
      {
        "container.env": {
          "SENTRY_RELEASE": "${{ github.sha }}",
          "DEPLOYMENT_ID": "${{ github.run_id }}",
          "ENVIRONMENT": "production"
        }
      }
```

This patches environment files (like `container.env` or `.env`) that are used by Kustomize's `configMapGenerator`. This approach is cleaner for GitOps as changes are visible in the actual config files.

### Multiple environment files
```yaml
- name: Patch multiple env files
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/production
    env_patches: |
      {
        "container.env": {
          "API_URL": "https://api.production.example.com",
          "ENVIRONMENT": "production"
        },
        "secrets.env": {
          "SENTRY_DSN": "${{ secrets.SENTRY_DSN }}"
        }
      }
```

### Update multiple images
```yaml
- name: Update API image
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/dev
    image: api
    tag: latest

- name: Update worker image
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/dev
    image: worker
    tag: latest
```

### With namespace override
```yaml
- name: Update for feature branch
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/feature
    image: app
    tag: feature-${{ github.event.number }}
    namespace: pr-${{ github.event.number }}
```

## Image Input Formats

This action supports three formats for specifying images:

### 1. Separate image and tag (recommended)
```yaml
image: registry.io/app
tag: v1.2.3
```

### 2. Embedded tag (backwards compatible)
```yaml
image: registry.io/app:v1.2.3
```

### 3. Multiple images (via JSON)
```yaml
images_json: |
  [
    {"name": "registry.io/app", "newTag": "v1.2.3"},
    {"name": "registry.io/app-migrator", "newTag": "v1.2.3"}
  ]
```

## Multiple Images Support

The `images_json` input allows you to update multiple container images in a single action call. This is particularly useful for:

- **Main + auxiliary images** (e.g., app + migrator, app + sidecar)
- **Microservices with multiple containers** in the same deployment
- **Services with init containers** that need version pinning

### Format

The `images_json` input expects a JSON array matching [Kustomize's native image format](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/images/):

```json
[
  {
    "name": "registry.io/app",
    "newTag": "v1.2.3"
  },
  {
    "name": "registry.io/app-migrator",
    "newTag": "v1.2.3"
  }
]
```

**Required fields:**
- `name` - Full image name/repository (e.g., `gcr.io/project/image` or `myapp`)
- `newTag` - New tag to set (e.g., `v1.2.3`, `latest`, `main-abc123`)

**Mutual Exclusivity:**
Provide either `images_json` OR `image` (with or without tag), not both. The action will error if both are provided.

### Example: Service with database migrator

```yaml
- name: Update app and migrator images
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/production
    images_json: |
      [
        {"name": "europe-docker.pkg.dev/myproject/myapp", "newTag": "${{ github.sha }}"},
        {"name": "europe-docker.pkg.dev/myproject/myapp-migrator", "newTag": "${{ github.sha }}"}
      ]
```

## How It Works

This action is the **single source of truth** for image input handling in the Skyhook action ecosystem. It:

1. **Validates and normalizes** all image input formats (embedded tag, separate params, or multi-image JSON)
2. **Modifies** `kustomization.yaml` using kustomize CLI commands
3. **Updates** labels, annotations, and other kustomize fields
4. **Validates** that the final kustomization builds successfully

Higher-level orchestrator actions like `kustomize-deploy` delegate all image handling to this action, ensuring consistent behavior across the ecosystem.

### Example Transformation

The action modifies `kustomization.yaml`:

### Before
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
images:
  - name: backend
    newTag: v1.0.0
```

### After
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
images:
  - name: backend
    newTag: v1.2.3
commonLabels:
  version: v1.2.3
commonAnnotations:
  last-deployed: "2024-01-15T10:30:00Z"
```

## Environment File Patching

The `env_patches` input integrates with [skyhook-io/patch-env-files](https://github.com/skyhook-io/patch-env-files) to update environment files used by Kustomize's `configMapGenerator`.

### How it works

If your kustomization.yaml includes:
```yaml
configMapGenerator:
  - name: app-config
    envs:
      - container.env
```

You can patch `container.env` with runtime values:
```yaml
- uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/production
    env_patches: |
      {
        "container.env": {
          "VERSION": "${{ github.sha }}",
          "BUILD_NUMBER": "${{ github.run_number }}"
        }
      }
```

### Benefits

1. **GitOps friendly** - Changes are visible in actual files
2. **Simpler** - Direct file updates instead of JSON patch operations
3. **More flexible** - Can update multiple env files independently
4. **Better diffs** - Git shows actual configuration changes

## Advanced Usage

### Working with different container registries

The action supports both simple image names and full registry paths. This is useful when:
- Your images are stored in different registries (Docker Hub, GCR, ECR, etc.)
- You need to specify exactly which registry to pull from
- You're using private or corporate registries

```yaml
# Simple image name (uses default registry)
- name: Update from Docker Hub
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/production
    image: nginx
    tag: 1.21

# Full registry path for Google Container Registry
- name: Update from GCR
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/production
    image: gcr.io/my-project/backend
    tag: v1.2.3

# Private registry example
- name: Update from private registry
  uses: skyhook-io/kustomize-edit@v1
  with:
    overlay_dir: deploy/overlays/production
    image: registry.company.com/team/api-service
    tag: ${{ github.sha }}
```

When you provide the full registry path, kustomize knows exactly which image entry to update in your kustomization.yaml, even if you have multiple images with the same base name from different registries.

## Notes

- **Backwards compatible**: Supports legacy `image:tag` format automatically
- **Three input formats**: Embedded tag, separate params, or multi-image JSON
- **Used by orchestrators**: `kustomize-deploy` and other actions delegate to this for image handling
- Preserves existing kustomization.yaml structure
- Creates kustomization.yaml if it doesn't exist
- Supports both `newTag` and `newName` patterns
- Works with strategic merge patches
- Compatible with kubectl 1.14+
