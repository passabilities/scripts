# DGB Scripts

A comprehensive collection of shell scripts for AWS infrastructure automation, deployment, and monitoring. Scripts are organized in logical subdirectories with automated symlink management for easy PATH accessibility.

## Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Available Scripts](#available-scripts)
  - [AWS Visualization Tools](#aws-visualization-tools)
- [Usage](#usage)
- [Development](#development)
- [Configuration](#configuration)
- [Contributing](#contributing)

## Features

- **Organized Structure**: Scripts organized in logical subdirectories under `src/`
- **Automated Symlinks**: Flat symlinks in `bin/` for PATH accessibility
- **Git Hooks**: Pre-commit hook automatically updates symlinks
- **Interactive Prompts**: Beautiful npm-style UI with arrow key navigation
- **AWS Integration**: Comprehensive AWS resource discovery and monitoring
- **Project-Based**: Support for multi-project environments with filtering
- **Environment Discovery**: Automatic detection of existing AWS environments

## Architecture

### Directory Structure

```
scripts/
├── src/                    # Source scripts (organized by category)
│   ├── aws/               # AWS-related scripts
│   │   └── vis/          # Visualization and monitoring tools
│   └── lib/              # Shared libraries (sourced, not executed)
├── bin/                   # Auto-generated symlinks (flat structure)
├── setup-bin.sh          # Symlink management utility
└── .git/hooks/           # Git hooks for automation
    └── pre-commit        # Auto-runs setup-bin.sh
```

### How It Works

1. **Scripts** are created in logical subdirectories under `src/`
2. **Symlinks** are auto-generated in `bin/` with flattened names
   - Example: `src/aws/deploy.sh` → `bin/aws-deploy.sh`
3. **Git hooks** automatically regenerate symlinks on commit
4. **Libraries** in `src/lib/` are sourced by scripts (no `.sh` extension)

### Why This Architecture?

Shell scripts in PATH directories must be directly accessible (subdirectories are not searched). This architecture provides:
- Logical organization in `src/` subdirectories
- Flat structure in `bin/` for PATH accessibility
- Automatic synchronization via git hooks
- Clear separation between executable scripts and sourced libraries

## Installation

### Prerequisites

- Bash 4.0 or higher
- Git
- AWS CLI (for AWS scripts)
- jq (for JSON processing in AWS scripts)

### Setup

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd scripts
   ```

2. Generate symlinks:
   ```bash
   ./setup-bin.sh
   ```

3. (Optional) Add `bin/` to your PATH:
   ```bash
   echo 'export PATH="$PATH:/path/to/scripts/bin"' >> ~/.bashrc
   source ~/.bashrc
   ```

4. For AWS scripts, configure AWS CLI:
   ```bash
   aws configure
   ```

## Quick Start

### Running Scripts

If `bin/` is in your PATH:
```bash
# Run by flattened name
aws-vis-status-dashboard.sh
```

Otherwise:
```bash
# Run from bin directory
./bin/aws-vis-status-dashboard.sh

# Or run source directly
./src/aws/vis/status-dashboard.sh
```

### Creating a New Script

1. Create your script in the appropriate subdirectory:
   ```bash
   touch src/category/my-script.sh
   vim src/category/my-script.sh
   ```

2. Add shebang and make it executable (optional, setup-bin.sh handles this):
   ```bash
   #!/bin/bash
   ```

3. Regenerate symlinks:
   ```bash
   ./setup-bin.sh
   # Or just commit - the pre-commit hook handles it
   git add src/category/my-script.sh
   git commit -m "Add my new script"
   ```

## Available Scripts

### AWS Visualization Tools

Located in `src/aws/vis/`, these tools provide comprehensive AWS infrastructure monitoring and visualization.

#### Status Dashboard (`aws-vis-status-dashboard.sh`)

Real-time infrastructure health monitoring with color-coded status indicators.

**Features:**
- Live status monitoring for all AWS resources
- Health indicators: healthy/warning/critical/unknown
- Supported resources: VPC, RDS, ElastiCache, S3, SES, Elastic Beanstalk
- Project-based filtering or "show all" mode
- Visual separation between resource types
- Regional filtering for S3 buckets

**Usage:**
```bash
./bin/aws-vis-status-dashboard.sh
```

**Example Output:**
```
╔═══════════════════════════════════════════════════════════════════════════╗
║  VPC & Network
╟───────────────────────────────────────────────────────────────────────────╢
║  ✓  VPC                    my-project-vpc                   available
║  ✓  Internet Gateway       igw-xxx                          available
╚═══════════════════════════════════════════════════════════════════════════╝

╔═══════════════════════════════════════════════════════════════════════════╗
║  Database (RDS)
╟───────────────────────────────────────────────────────────────────────────╢
║  ✓  RDS Instance           my-project-db                    available
╚═══════════════════════════════════════════════════════════════════════════╝
```

#### Discover Resources (`aws-vis-discover-resources.sh`)

Automated resource discovery with tag-based project filtering.

**Features:**
- Scans all AWS resources in a region
- Tag-based project filtering (Project tag)
- JSON output for automation and integration
- Discovers: VPC, Subnets, Security Groups, RDS, ElastiCache, S3, SES, Elastic Beanstalk

**Usage:**
```bash
./bin/aws-vis-discover-resources.sh
```

**Output Format:**
JSON with resource types, IDs, names, and relationships

#### Infrastructure Visualization (`aws-vis-infra.sh`)

ASCII diagram generation of infrastructure with dependency mapping.

**Features:**
- ASCII architecture diagrams
- Dependency tree visualization
- Resource relationship mapping
- Empty state handling with helpful suggestions
- Dynamic VPC labeling based on filter mode

**Usage:**
```bash
./bin/aws-vis-infra.sh
```

**Example Output:**
```
                        ┌─────┐
                        │     │
                    ┌───┤ AWS ├───┐
                    │   │     │   │
                    │   └─────┘   │
╔═══════════════════════════════════════════════════════════════╗
║  VPC (my-project-vpc)                                         ║
║                   │                                           ║
║            ┌──────▼──────┐                                    ║
║            │ Internet GW │                                    ║
║            └──────┬──────┘                                    ║
╚═══════════════════════════════════════════════════════════════╝
```

### Configuration Options

All AWS visualization scripts support:

- **Interactive configuration prompts** with environment discovery
- **Project-based filtering** using Project tags
- **"Show all resources" mode** to ignore filters
- **Configuration file** loading from `aws-config.env`
- **Environment auto-discovery** from Elastic Beanstalk applications

## Usage

### Interactive Configuration

When you run any AWS visualization script, you'll be prompted to:

1. **Select or create a project**
   - Choose from discovered AWS projects
   - Create a new project
   - Show all resources (no filter)

2. **Select environment** (if project chosen)
   - Discovered environments from Elastic Beanstalk
   - Standard environments (development/staging/production)
   - Custom environment name

3. **Choose AWS region**
   - Select from list of AWS regions
   - Custom region

### Configuration File

Create `aws-config.env` in the script directory to save your configuration:

```bash
PROJECT_NAME="my-project"
ENVIRONMENT="production"
AWS_REGION="us-east-1"
```

Scripts will automatically load these values if available.

### Resource Naming Conventions

For best results with project filtering, follow these naming patterns:

- **VPC**: `{PROJECT_NAME}-vpc` or tagged with `Project={PROJECT_NAME}`
- **RDS**: `{PROJECT_NAME}-db` or `{PROJECT_NAME}-{ENV}-db`
- **ElastiCache**: `{PROJECT_NAME}-redis` or `{PROJECT_NAME}-cache`
- **Elastic Beanstalk**: `{PROJECT_NAME}-app-{ENVIRONMENT}`
- **S3 Buckets**: Contains `{PROJECT_NAME}` in the name
- **Security Groups**: Tagged with `Project={PROJECT_NAME}`

## Development

### Adding New Scripts

1. **Choose the right directory** under `src/`
   - Use existing subdirectories or create new ones
   - Group related scripts together

2. **Naming conventions**:
   - Executable scripts: Include `.sh` extension
   - Libraries (sourced): NO `.sh` extension
   - Use lowercase with hyphens: `my-script.sh`

3. **Script template**:
   ```bash
   #!/bin/bash

   # Get script directory (works when run from anywhere)
   SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

   # For sourcing libraries
   LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/src/lib"
   source "${LIB_DIR}/prompts"
   ```

4. **Test and commit**:
   ```bash
   ./src/category/my-script.sh  # Test
   git add src/category/my-script.sh
   git commit -m "feat: add my new script"
   # Pre-commit hook automatically updates bin/
   ```

### Using Shared Libraries

Available libraries in `src/lib/`:

#### `prompts` - Interactive Prompts
```bash
source "${LIB_DIR}/prompts"

# Text input with validation
prompt_text VAR "Enter value" "default" "^[a-z]+$"

# Select menu
prompt_select CHOICE "Select option" 0 "Option 1" "Option 2"

# Select or custom input
prompt_select_or_custom VAR "Choose" "default" "opt1" "opt2"

# Confirmation
prompt_confirm "Continue?" && echo "Yes!"

# Display functions
prompt_header "Title" "Description"
prompt_success "Success message"
prompt_error "Error message"
prompt_warning "Warning message"
prompt_info "Info message"
```

#### `config-display` - Configuration Display
```bash
source "${LIB_DIR}/config-display"

display_config "header" "Title" "Description"
display_config "compact" "Title" "Description"
display_config "inline" "Label" "value"
display_config "summary" "Title" "message"
```

#### `config-prompt` - AWS Configuration
```bash
source "${LIB_DIR}/config-prompt"

# Discover AWS projects
projects=$(discover_aws_projects)

# Discover environments for a project
envs=$(discover_project_environments "$PROJECT_NAME")

# Prompt for AWS configuration
prompt_aws_config "true" "visualization"
# Returns: PROJECT_NAME, ENVIRONMENT, AWS_REGION exported
```

### Git Workflow

```bash
# 1. Create or edit scripts in src/
vim src/category/new-script.sh

# 2. Test the script
./src/category/new-script.sh

# 3. Commit changes
git add src/category/new-script.sh
git commit -m "feat: add new script"
# Pre-commit hook automatically updates bin/

# 4. Push changes
git push
```

### Manual Symlink Regeneration

```bash
# Regenerate all symlinks
./setup-bin.sh

# Output shows all created symlinks:
#   src/category/script.sh -> bin/category-script.sh
#   Done! Created N symlinks in bin/
```

## Configuration

### Git Configuration

This repository uses SSH for git operations. Ensure your git remotes use SSH URLs:

```bash
git remote -v
# Should show: git@github.com:user/repo.git (not https://)
```

### Pre-commit Hook

The pre-commit hook (`.git/hooks/pre-commit`):
1. Runs `./setup-bin.sh` to regenerate symlinks
2. Checks for changes in `bin/` directory
3. Automatically stages `bin/` changes if detected
4. Allows commit to proceed

This ensures `bin/` always stays synchronized with `src/` in version control.

### AWS Credentials

Configure AWS CLI with your credentials:

```bash
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region name: us-east-1
# Default output format: json
```

Or use environment variables:
```bash
export AWS_ACCESS_KEY_ID="your-key"
export AWS_SECRET_ACCESS_KEY="your-secret"
export AWS_DEFAULT_REGION="us-east-1"
```

## Contributing

### Code Style

- Use 4-space indentation
- Follow existing script patterns
- Use descriptive variable names
- Add comments for complex logic
- Always use absolute paths (derived from `$SCRIPT_DIR`)

### Testing

Before committing:
1. Test your script from different directories
2. Verify it works when run via symlink
3. Check that library sourcing works correctly
4. Test with and without configuration files

### Pull Requests

1. Create a feature branch
2. Make your changes
3. Test thoroughly
4. Commit with conventional commit messages
5. Push and create a pull request

### Commit Message Format

Use conventional commits:
```
type(scope): description

[optional body]

[optional footer]
```

Types: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `style`, `chore`, `build`, `ci`

Examples:
```
feat(aws): add EC2 instance monitoring script
fix(lib): correct path resolution for nested scripts
docs: update README with new AWS tools
```

## License

[Your License Here]

## Support

For issues or questions:
- Create an issue on GitHub
- Check `CLAUDE.md` for detailed development guidelines
- Review existing scripts for examples

## Acknowledgments

Built with:
- Bash scripting
- AWS CLI
- Git hooks for automation
- Interactive prompts library
