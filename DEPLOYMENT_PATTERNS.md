# Deployment Patterns: What Runs Where?

## The Current Approach

**This repository now uses a pipeline-first architecture:**
- CodeBuild handles ALL building (via buildspec.yml)
- appspec.yml hooks handle ONLY deployment configuration
- Manual deployments (via deploy.sh) deploy pre-built artifacts

**No more building on EC2 instances or in deployment scripts!**

---

## The CI/CD Pattern (Primary Workflow)

### With CodePipeline + CodeBuild

**buildspec.yml does the heavy lifting:**
```yaml
version: 0.2

phases:
  install:
    runtime-versions:
      nodejs: 18
  pre_build:
    commands:
      - npm ci                    # Install dependencies
  build:
    commands:
      - npm run build             # Build the project
      - npm prune --production    # Remove dev dependencies

artifacts:
  files:
    - 'dist/**/*'                 # Only deploy BUILT files
    - 'node_modules/**/*'         # Prod dependencies only
    - 'package.json'
    - 'scripts/**/*'
  exclude-paths:
    - 'src/**/*'                  # Don't deploy source code
    - '.git/**/*'
```

**appspec.yml just deploys pre-built artifacts:**
```yaml
version: 0.0
os: linux
files:
  - source: /
    destination: /app

hooks:
  ApplicationStop:
    - location: scripts/stop_server.sh
      timeout: 60
      runas: ubuntu

  AfterInstall:
    - location: scripts/after_install.sh
      timeout: 300
      runas: root
      # Just fetch env vars and set permissions
      # NO npm install, NO npm build

  ApplicationStart:
    - location: scripts/start_server.sh
      timeout: 300
      runas: ubuntu
      # Just start the pre-built app
```

**scripts/after_install.sh:**
```bash
#!/bin/bash
set -e

# Fetch runtime environment variables
/app/scripts/fetch_env.sh

# Set proper permissions
chown -R ubuntu:ubuntu /app
chmod +x /app/scripts/*.sh

# That's it! No build steps here!
```

**scripts/start_server.sh:**
```bash
#!/bin/bash
set -e

cd /app

# Start the PRE-BUILT application
pm2 start dist/index.js --name myapp

# Or for Python:
# source venv/bin/activate
# gunicorn app:app
```

---

## What Should NEVER Happen

### ❌ WRONG: Building in Both Places
```yaml
# buildspec.yml
build:
  commands:
    - npm install    # ✅ Good
    - npm run build  # ✅ Good

# appspec.yml hooks
AfterInstall:
  - scripts/after_install.sh
```

```bash
# after_install.sh
npm install    # ❌ WRONG! Already done in build
npm run build  # ❌ WRONG! Already done in build
```

**Why this is bad:**
- Wastes time (installs twice, builds twice)
- EC2 instances need build tools (node, npm, compilers)
- Increases deployment time from seconds to minutes
- Can fail if EC2 doesn't have build dependencies

### ✅ CORRECT: Build Once, Deploy Everywhere
```yaml
# buildspec.yml - Build ONCE in CodeBuild
build:
  commands:
    - npm install
    - npm run build

# appspec.yml hooks - Deploy pre-built artifact
AfterInstall:
  - scripts/after_install.sh
```

```bash
# after_install.sh - NO BUILD STEPS
fetch_env.sh       # ✅ Get runtime config
chown ubuntu:ubuntu  # ✅ Set permissions
# That's it!
```

---

## How to Fix If You Have Both

### Current Setup Review

Check your `after_install.sh`:
```bash
cat scripts/after_install.sh
```

If you see:
```bash
npm install    # ❌ Remove this
npm run build  # ❌ Remove this
cd /app
pm2 start dist/index.js  # ✅ Keep this
```

### Fix: Remove Build Steps from Hooks

**Updated after_install.sh (for pipeline):**
```bash
#!/bin/bash
set -e

echo "Fetching runtime environment variables..."
/app/scripts/fetch_env.sh

echo "Setting permissions..."
chown -R ubuntu:ubuntu /app
chmod +x /app/scripts/*.sh

echo "Deployment preparation complete"
```

**Updated start_server.sh:**
```bash
#!/bin/bash
set -e

cd /app

# Load environment
export $(cat .env | xargs)

# Start the pre-built application
pm2 start dist/index.js --name myapp -i max

echo "Application started"
```

---

## Build Artifacts: What to Include

### With CodeBuild Pipeline

**Include in artifacts (buildspec.yml):**
```yaml
artifacts:
  files:
    - 'dist/**/*'              # Built JavaScript
    - 'node_modules/**/*'      # Production dependencies only
    - 'package.json'
    - 'appspec.yml'           # CodeDeploy needs this
    - 'scripts/**/*'          # Lifecycle hooks
  exclude-paths:
    - 'src/**/*'              # Exclude source TypeScript
    - 'test/**/*'             # Exclude tests
    - '.git/**/*'
    - 'node_modules/.cache/**/*'
```

**Why exclude source?**
- Smaller artifact size
- Faster deployments
- More secure (only deploy compiled code)
- EC2 doesn't need TypeScript compiler

### Without CodeBuild (Manual)

**Include in artifact (aws-cd-deploy.sh):**
```bash
# Builds locally, includes everything needed
dist/
node_modules/
package.json
appspec.yml
scripts/
```

---

## When EC2 Instances Need Build Tools

### ❌ With Pipeline: NO BUILD TOOLS NEEDED
```bash
# EC2 instances don't need:
- node/npm
- TypeScript compiler
- Webpack/Vite
- Python pip
- Maven/Gradle

# EC2 instances only need:
- Node runtime (to run dist/index.js)
- PM2 (process manager)
- AWS CLI (for fetch_env.sh)
```

### ✅ Without Pipeline: BUILD TOOLS OPTIONAL
```bash
# If you build locally:
- EC2 doesn't need build tools
- Deploy the built artifact

# If you build on EC2 (not recommended):
- EC2 needs full build environment
- Slower deployments
- More things that can break
```

---

## Summary

**The Golden Rule:**
> If CodeBuild builds it, appspec.yml hooks should NOT build it again.

**What appspec.yml hooks SHOULD do:**
1. Stop the running application
2. Fetch runtime environment variables
3. Set file permissions
4. Start the application

**What appspec.yml hooks should NOT do:**
1. ❌ Install dependencies (already in artifact)
2. ❌ Compile/build code (already done by CodeBuild)
3. ❌ Run tests (already done in pipeline)

**Correct flow:**
```
CodeBuild (buildspec.yml)
  └─> Installs deps, builds, tests
      └─> Creates artifact.zip
          └─> CodeDeploy (appspec.yml)
              └─> Extracts artifact
                  └─> Fetches runtime config
                      └─> Starts pre-built app
```

---

## Next Steps

1. **Review your appspec.yml hooks** - Remove any build/install commands
2. **Update buildspec.yml artifacts** - Ensure you're including built files
3. **Test a deployment** - Should be much faster now!
4. **Check EC2 instance** - Verify built files are being deployed

If your hooks are doing builds, that's a configuration smell that needs fixing!
