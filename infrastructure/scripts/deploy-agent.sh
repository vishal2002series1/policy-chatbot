#!/bin/bash

# Configuration
AGENT_NAME="policy-chatbot"
INSTRUCTION=$(cat src/agent/prompts/base_instruction.txt 2>/dev/null || echo "Default instruction text")
FOUNDATION_MODEL="anthropic.claude-v2"
DESCRIPTION="Policy Information Chatbot"
TTL=1800
ROLE_ARN="arn:aws:iam::258574424891:role/BedrockModelCustomizationRole"
KNOWLEDGE_BASE_ID="policy-chatbot-kb-id"

# Check for jq
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq to continue."
    exit 1
fi

# Check AWS CLI
if ! aws sts get-caller-identity &> /dev/null; then
    echo "Error: AWS CLI is not configured properly. Please configure AWS CLI with valid credentials."
    exit 1
fi

echo "Checking for existing agent named '$AGENT_NAME'..."
# AGENTS_JSON=$(aws bedrock-agent list-agents --output json 2>/dev/null || echo '{"agents":[]}')
# echo "AGENTS_JSON: $AGENTS_JSON"
# AGENT_ID=$(echo "$AGENTS_JSON" | jq -r --arg NAME "$AGENT_NAME" '(.agents // [])[] | select(.agentName == $NAME) | .agentId')

AGENTS_JSON=$(aws bedrock-agent list-agents --output json 2>/dev/null || echo '{"agentSummaries":[]}')
echo "AGENTS_JSON: $AGENTS_JSON"
AGENT_ID=$(echo "$AGENTS_JSON" | jq -r --arg NAME "$AGENT_NAME" '(.agentSummaries // [])[] | select(.agentName == $NAME) | .agentId')


if [ -z "$AGENT_ID" ]; then
    echo "No existing agent found. Creating new agent..."
    CREATE_RESPONSE=$(aws bedrock-agent create-agent \
        --agent-name "$AGENT_NAME" \
        --foundation-model "$FOUNDATION_MODEL" \
        --agent-resource-role-arn "$ROLE_ARN" \
        --instruction "$INSTRUCTION" \
        --description "$DESCRIPTION" \
        --idle-session-ttl-in-seconds $TTL \
        --output json 2>/dev/null)
    AGENT_ID=$(echo "$CREATE_RESPONSE" | jq -r '.agent.agentId')
    if [ -z "$AGENT_ID" ] || [ "$AGENT_ID" = "null" ]; then
        echo "Failed to create agent: $CREATE_RESPONSE"
        exit 1
    fi
    echo "Created new agent with ID: $AGENT_ID"
else
    echo "Found existing agent with ID: $AGENT_ID"
fi

echo "Checking for existing knowledge base with ID '$KNOWLEDGE_BASE_ID'..."
KBS_JSON=$(aws bedrock-agent list-knowledge-bases --output json 2>/dev/null || echo '{"knowledgeBases":[]}')
KB_EXISTS=$(echo "$KBS_JSON" | jq -r --arg KBID "$KNOWLEDGE_BASE_ID" '.knowledgeBases[]? | select(.knowledgeBaseId == $KBID) | .knowledgeBaseId')

if [ -z "$KB_EXISTS" ]; then
    echo "Warning: Knowledge base with ID $KNOWLEDGE_BASE_ID not found."
    echo "Please create the knowledge base first or update KNOWLEDGE_BASE_ID."
    exit 1
fi

echo "Checking if knowledge base is already associated..."
AGENT_KBS_JSON=$(aws bedrock-agent list-agent-knowledge-bases --agent-id "$AGENT_ID" --output json 2>/dev/null || echo '{"agentKnowledgeBases":[]}')
KB_ASSOCIATED=$(echo "$AGENT_KBS_JSON" | jq -r --arg KBID "$KNOWLEDGE_BASE_ID" '.agentKnowledgeBases[]? | select(.knowledgeBaseId == $KBID) | .knowledgeBaseId')

if [ -z "$KB_ASSOCIATED" ]; then
    echo "Associating knowledge base with agent..."
    aws bedrock-agent associate-agent-knowledge-base \
        --agent-id "$AGENT_ID" \
        --knowledge-base-id "$KNOWLEDGE_BASE_ID"
    echo "Associated knowledge base: $KNOWLEDGE_BASE_ID"
else
    echo "Knowledge base already associated with agent."
fi

echo "Checking for existing agent versions..."
VERSIONS_JSON=$(aws bedrock-agent list-agent-versions --agent-id "$AGENT_ID" --output json 2>/dev/null || echo '{"agentVersions":[]}')
LATEST_VERSION=$(echo "$VERSIONS_JSON" | jq -r '.agentVersions | sort_by(.creationDateTime) | last | .agentVersion')

if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then
    echo "No existing version found. Preparing new version..."
    PREPARE_RESPONSE=$(aws bedrock-agent prepare-agent --agent-id "$AGENT_ID" --output json 2>/dev/null)
    AGENT_VERSION=$(echo "$PREPARE_RESPONSE" | jq -r '.agentVersion.agentVersion')
    if [ -z "$AGENT_VERSION" ] || [ "$AGENT_VERSION" = "null" ]; then
        echo "Failed to prepare agent version: $PREPARE_RESPONSE"
        exit 1
    fi
    echo "Prepared new agent version: $AGENT_VERSION"
else
    AGENT_VERSION=$LATEST_VERSION
    echo "Using existing latest version: $AGENT_VERSION"
fi

echo "Checking for existing 'LATEST' alias..."
ALIASES_JSON=$(aws bedrock-agent list-agent-aliases --agent-id "$AGENT_ID" --output json 2>/dev/null || echo '{"agentAliases":[]}')
EXISTING_ALIAS=$(echo "$ALIASES_JSON" | jq -r '.agentAliases[]? | select(.agentAliasName == "LATEST") | .agentAliasId')

if [ -z "$EXISTING_ALIAS" ] || [ "$EXISTING_ALIAS" = "null" ]; then
    echo "Creating new 'LATEST' alias..."
    ALIAS_CREATE_RESPONSE=$(aws bedrock-agent create-agent-alias \
        --agent-id "$AGENT_ID" \
        --agent-alias-name "LATEST" \
        --routing-configuration agentVersion="$AGENT_VERSION" \
        --output json 2>/dev/null)
    ALIAS_ID=$(echo "$ALIAS_CREATE_RESPONSE" | jq -r '.agentAlias.agentAliasId')
    if [ -z "$ALIAS_ID" ] || [ "$ALIAS_ID" = "null" ]; then
        echo "Failed to create agent alias: $ALIAS_CREATE_RESPONSE"
        exit 1
    fi
    echo "Created new agent alias with ID: $ALIAS_ID"
else
    echo "Updating existing 'LATEST' alias to point to version $AGENT_VERSION..."
    aws bedrock-agent update-agent-alias \
        --agent-id "$AGENT_ID" \
        --agent-alias-id "$EXISTING_ALIAS" \
        --routing-configuration agentVersion="$AGENT_VERSION"
    echo "Updated existing alias: $EXISTING_ALIAS"
fi

echo "Deployment completed successfully!"
echo "Agent ID: $AGENT_ID"
echo "Agent Version: $AGENT_VERSION"
echo "Knowledge Base ID: $KNOWLEDGE_BASE_ID"