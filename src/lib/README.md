# Shared Script Libraries

This directory contains reusable libraries for all scripts in the repository.

## Available Libraries

### `prompts`
Interactive prompts library with npm-style UI.

### `config-prompt` ⭐
Interactive configuration prompting system for AWS scripts.

### `config-display`
Configuration display utilities with beautiful formatting.

---

## `prompts` - Interactive Prompts Library

**Features:**
- ✨ Beautiful, colorful terminal UI
- ⌨️ Arrow key navigation for selections
- ✓ Input validation
- 🎨 Consistent styling across all prompts

**Functions:**

#### `prompt_text VAR_NAME "Question" "default" "regex"`
Text input with optional validation.

```bash
prompt_text PROJECT_NAME "Project name" "myproject" "^[a-z0-9-]+$"
# Result: PROJECT_NAME="user-input"
```

#### `prompt_select VAR_NAME "Question" default_index "option1" "option2" ...`
Select from options using arrow keys.

```bash
prompt_select ENVIRONMENT "Environment" 1 "dev" "staging" "prod"
# User navigates with ↑↓ arrows, presses Enter
```

#### `prompt_select_or_custom VAR_NAME "Question" "default" "opt1" "opt2" ...`
Select from options OR enter custom value.

```bash
prompt_select_or_custom REGION "AWS Region" "us-east-1" \
    "us-east-1" "us-west-2" "eu-west-1"
# Shows options plus "Custom value..." at the end
```

#### `prompt_confirm VAR_NAME "Question" "yes|no"`
Yes/no confirmation.

```bash
prompt_confirm ENABLE_LOGS "Enable logging?" "yes"
# Result: ENABLE_LOGS="yes" or "no"
```

#### Display Functions

```bash
prompt_header "Section Title" "Optional description"
prompt_info "Information message"
prompt_success "Success message"
prompt_warning "Warning message"
prompt_error "Error message"
```

**Example Script:**

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/src/lib"
source "${LIB_DIR}/prompts"

prompt_header "Setup Wizard" "Configure your application"

prompt_text APP_NAME "Application name" "myapp" "^[a-z0-9-]+$"
prompt_select_or_custom ENVIRONMENT "Environment" "staging" "dev" "staging" "prod"
prompt_confirm ENABLE_SSL "Enable SSL?" "yes"

prompt_success "Configuration complete!"
```

---

### `config-prompt` ⭐
Interactive configuration prompting system - applies to ALL scripts.

**Features:**
- 🔄 Automatically loads existing configuration
- ✏️ Prompts user to confirm or modify values
- 🌐 Option to show ALL resources (visualization scripts)
- 💾 Save configuration on the fly
- 🔗 Launch full configuration wizard if needed

**Functions:**

#### `prompt_aws_config [allow_show_all] [script_type]`
Main configuration prompting function.

```bash
# For setup scripts
prompt_aws_config "false" "setup"

# For visualization scripts (allows "show all" option)
prompt_aws_config "true" "visualization"
```

**Behavior:**
1. Loads existing configuration from `aws-config.env` if available
2. Discovers existing projects from AWS (scans VPCs, RDS, Security Groups for Project tags)
3. Prompts user to:
   - Select from existing projects
   - Create a new project
   - Show ALL resources (if `allow_show_all=true`)
   - Modify current configuration
4. Displays current configuration and asks for confirmation
5. Optionally saves updated configuration

#### `display_config_summary()`
Display active configuration summary (called after `prompt_aws_config`).

```bash
display_config_summary
```

**Output:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Active Configuration:

  ▸ Project:     myproject
  ▸ Environment: staging
  ▸ Region:      us-east-1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### `is_filtering_by_project()`
Check if script is filtering resources by project.

```bash
if is_filtering_by_project; then
    # Query specific resources for this project
else
    # Query ALL resources
fi
```

#### `get_project_filter()`
Get AWS CLI filter for project tag.

```bash
local filter=$(get_project_filter)
# Returns: "Name=tag:Project,Values=myproject" or ""
```

#### `get_project_name()`
Get project name for queries (with wildcard if showing all).

```bash
local project=$(get_project_name)
# Returns: "myproject" or "*"
```

#### `confirm_destructive_action "description" [count]`
Double-confirmation for destructive operations.

```bash
if confirm_destructive_action "delete all infrastructure" "15"; then
    # Proceed with deletion
fi
```

**Example Script:**

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/src/lib"

source "${LIB_DIR}/prompts"
source "${LIB_DIR}/config-display"
source "${LIB_DIR}/config-prompt"

# Prompt for configuration (allow "show all" for visualization)
prompt_aws_config "true" "visualization"

# Display active configuration
display_config_summary

# Use configuration in queries
if is_filtering_by_project; then
    echo "Querying resources for project: ${PROJECT_NAME}"
    # Query specific project resources
else
    echo "Querying ALL resources in region: ${AWS_REGION}"
    # Query all resources
fi
```

---

### `config-display`
Configuration display utilities for showing current settings in an elegant format.

**Features:**
- 📋 Beautiful formatted configuration panels
- 📊 Summary boxes with borders
- 🎨 Color-coded values
- 📐 Responsive layout

**Functions:**

#### `config_display_summary "Script Name"`
Display a formatted configuration summary panel.

```bash
config_display_summary "AWS Infrastructure Setup"
```

**Output:**
```
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║                      AWS Infrastructure Setup                             ║
║                                                                           ║
╠═══════════════════════════════════════════════════════════════════════════╣
║  Project Name:           myproject                                        ║
║  Display Name:           My Application                                   ║
║  Environment:            staging                                          ║
║  AWS Region:             us-east-1                                        ║
╟───────────────────────────────────────────────────────────────────────────╢
║  Database Name:          myproject                                        ║
║  Database User:          dbadmin                                          ║
║  DB Instance:            db.t3.micro                                      ║
╟───────────────────────────────────────────────────────────────────────────╢
║  Email Domain:           example.com                                      ║
║  From Email:             noreply@example.com                              ║
╚═══════════════════════════════════════════════════════════════════════════╝
```

**Variables Displayed (if set):**
- `PROJECT_NAME`, `PROJECT_DISPLAY_NAME`
- `ENVIRONMENT`, `AWS_REGION`
- `DB_NAME`, `DB_USER`, `DB_INSTANCE_CLASS`
- `EMAIL_DOMAIN`, `FROM_EMAIL`
- `EB_INSTANCE_TYPE`, `EB_MIN_INSTANCES`, `EB_MAX_INSTANCES`
- `VPC_CIDR`

#### `config_display_compact()`
Display a compact configuration sidebar.

```bash
config_display_compact
```

#### `config_display_inline()`
Display configuration as a single line.

```bash
config_display_inline
```

**Example Script:**

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/src/lib"
source "${LIB_DIR}/config-display"

# Load configuration
export PROJECT_NAME="myapp"
export ENVIRONMENT="production"
export AWS_REGION="us-east-1"
export DB_NAME="myapp_db"
export DB_USER="admin"

# Display configuration
config_display_summary "Database Setup"

# ... rest of script
```

---

## Usage Pattern

All scripts should use this pattern to source libraries:

```bash
#!/bin/bash
set -e

# Get script directory (works from anywhere)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Get library directory
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/src/lib"

# Source libraries
source "${LIB_DIR}/prompts"
source "${LIB_DIR}/config-display"
```

**Why this pattern?**
- Works when script is run from any directory
- Uses absolute paths derived from script location
- Portable across different environments
- No dependency on `pwd` or relative paths

---

## File Naming Convention

Library files in `src/lib/`:
- ❌ No `.sh` extension
- ✅ Lowercase names
- ✅ Hyphens for multi-word names
- ✅ Descriptive names

**Examples:**
- `prompts` ✓
- `config-display` ✓
- `utils` ✓
- `prompts.sh` ✗ (don't add .sh extension)
- `MyLib` ✗ (use lowercase)

---

## Color Codes Reference

Both libraries use consistent color schemes:

```bash
CYAN='\033[36m'      # Headers, borders, prompts
GREEN='\033[32m'     # Success, selected values
YELLOW='\033[33m'    # Warnings, defaults
RED='\033[31m'       # Errors
BLUE='\033[34m'      # Info messages
GRAY='\033[90m'      # Dim text
DIM='\033[2m'        # Dimmed text
BOLD='\033[1m'       # Bold text
RESET='\033[0m'      # Reset formatting
```

---

## Testing

Test the libraries with:

```bash
./bin/aws-test-prompts.sh
```

This demonstrates all prompt types and configuration display features.

---

## Contributing

When adding new library functions:

1. **Follow existing patterns** - Use similar naming and structure
2. **Document thoroughly** - Add function descriptions and examples
3. **Test extensively** - Ensure works from any directory
4. **Use colors consistently** - Follow the established color scheme
5. **Update this README** - Add your new functions to the documentation

---

## Examples

### Complete Configuration Script

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/src/lib"
source "${LIB_DIR}/prompts"
source "${LIB_DIR}/config-display"

clear

prompt_header "Application Setup" "Configure your application settings"

prompt_text APP_NAME "Application name" "myapp" "^[a-z0-9-]+$"
prompt_select ENVIRONMENT "Environment" 1 "development" "staging" "production"
prompt_select_or_custom REGION "Region" "us-east-1" \
    "us-east-1" "us-west-2" "eu-west-1"
prompt_confirm ENABLE_MONITORING "Enable monitoring?" "yes"

# Export for display
export PROJECT_NAME="$APP_NAME"
export ENVIRONMENT="$ENVIRONMENT"
export AWS_REGION="$REGION"

echo ""
prompt_header "Configuration Complete" "Review your settings"
config_display_summary "Application Setup"

prompt_confirm PROCEED "Proceed with setup?" "yes"

if [ "$PROCEED" = "yes" ]; then
    prompt_success "Starting setup..."
    # ... setup logic
else
    prompt_warning "Setup cancelled"
fi
```

### Simple Status Display

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/src/lib"
source "${LIB_DIR}/config-display"

# Source configuration
source "${SCRIPT_DIR}/config.env"

# Show configuration
config_display_summary "Deployment"

# ... deployment logic
```
