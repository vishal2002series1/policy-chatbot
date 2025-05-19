#!/bin/bash
set -e

# ---- CONFIGURATION ----
AGENT_NAME="policy-chatbot"
KB_NAME="policy-chatbot-kb"
INSTRUCTION=$(cat src/agent/prompts/base_instruction.txt 2>/dev/null || echo "Default instruction text")
FOUNDATION_MODEL="anthropic.claude-v2"
DESCRIPTION="Policy Information Chatbot"
TTL=1800
ROLE_ARN="arn:aws:iam::258574424891:role/BedrockModelCustomizationRole"
KB_ROLE_ARN="arn:aws:iam::258574424891:role/BedrockModelCustomizationRole"  # Use a role with KB permissions
EMBEDDING_MODEL_ARN="arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v1"
VECTOR_INDEX_NAME="policy-chatbot-index"
OPENSEARCH_COLLECTION_ARN="arn:aws:aoss:us-east-1:258574424891:collection/zboh61qa5fvxmrq2tswk"  # Replace with your collection ARN
REGION="us-east-1"

# ---- HELPER FUNCTIONS ----
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is not installed. Please install jq to continue."
        exit 1
    fi
}

check_aws_cli() {
    if ! aws sts get-caller-identity &> /dev/null; then
        echo "Error: AWS CLI is not configured properly. Please configure AWS CLI with valid credentials."
        exit 1
    fi
}

# ---- CHECK PREREQUISITES ----
check_jq
check_aws_cli

# ---- KNOWLEDGE BASE MANAGEMENT ----
echo "Checking for existing knowledge base named '$KB_NAME'..."
KBS_JSON=$(aws bedrock-agent list-knowledge-bases --region "$REGION" --output json 2>/dev/null || echo '{"knowledgeBases":[]}')
KB_ID=$(echo "$KBS_JSON" | jq -r --arg NAME "$KB_NAME" '(.knowledgeBases // [])[] | select(.knowledgeBaseName == $NAME) | .knowledgeBaseId')
KB_CREATE_TIME=$(echo "$KBS_JSON" | jq -r --arg NAME "$KB_NAME" '(.knowledgeBases // [])[] | select(.knowledgeBaseName == $NAME) | .createdAt')

# ---- DELETE KB IF OLDER THAN 24 HOURS ----
if [ -n "$KB_ID" ] && [ "$KB_ID" != "null" ]; then
    if [ -n "$KB_CREATE_TIME" ] && [ "$KB_CREATE_TIME" != "null" ]; then
        KB_CREATE_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$(echo $KB_CREATE_TIME | cut -d. -f1)" "+%s" 2>/dev/null || date -d "$KB_CREATE_TIME" "+%s")
        NOW_EPOCH=$(date "+%s")
        AGE=$(( (NOW_EPOCH - KB_CREATE_EPOCH) / 3600 ))
        if [ "$AGE" -ge 24 ]; then
            echo "Knowledge base '$KB_NAME' is older than 24 hours. Deleting..."
            aws bedrock-agent delete-knowledge-base --knowledge-base-id "$KB_ID" --region "$REGION"
            KB_ID=""
        fi
    fi
fi

# ---- CREATE KB IF NOT EXISTS ----
if [ -z "$KB_ID" ] || [ "$KB_ID" = "null" ]; then
    echo "No existing knowledge base found. Creating new knowledge base..."
    KB_CREATE_RESPONSE=$(aws bedrock-agent create-knowledge-base \
    --name "$KB_NAME" \
    --role-arn "$KB_ROLE_ARN" \
    --region "$REGION" \
    --knowledge-base-configuration '{
        "type": "VECTOR",
        "vectorKnowledgeBaseConfiguration": {
        "embeddingModelArn": "'"$EMBEDDING_MODEL_ARN"'"
        }
        }' \
    --storage-configuration '{
        "type": "OPENSEARCH_SERVERLESS",
        "opensearchServerlessConfiguration": {
        "collectionArn": "'"$OPENSEARCH_COLLECTION_ARN"'",
        "vectorIndexName": "'"$VECTOR_INDEX_NAME"'",
        "fieldMapping": {
            "vectorField": "vector",
            "textField": "text",
            "metadataField": "metadata"
        }
        }
    }' \
    --tags "created_by=deploy-agent,created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --output json)
    KB_ID=$(echo "$KB_CREATE_RESPONSE" | jq -r '.knowledgeBase.knowledgeBaseId')
    if [ -z "$KB_ID" ] || [ "$KB_ID" = "null" ]; then
        echo "Failed to create knowledge base: $KB_CREATE_RESPONSE"
        exit 1
    fi
    echo "Created new knowledge base with ID: $KB_ID"
else
    echo "Found existing knowledge base with ID: $KB_ID"
fi

# ---- AGENT MANAGEMENT ----
echo "Checking for existing agent named '$AGENT_NAME'..."
AGENTS_JSON=$(aws bedrock-agent list-agents --region "$REGION" --output json 2>/dev/null || echo '{"agentSummaries":[]}')
AGENT_ID=$(echo "$AGENTS_JSON" | jq -r --arg NAME "$AGENT_NAME" '(.agentSummaries // [])[] | select(.agentName == $NAME) | .agentId')

if [ -z "$AGENT_ID" ] || [ "$AGENT_ID" = "null" ]; then
    echo "No existing agent found. Creating new agent..."
    CREATE_RESPONSE=$(aws bedrock-agent create-agent \
        --agent-name "$AGENT_NAME" \
        --foundation-model "$FOUNDATION_MODEL" \
        --agent-resource-role-arn "$ROLE_ARN" \
        --instruction "$INSTRUCTION" \
        --description "$DESCRIPTION" \
        --idle-session-ttl-in-seconds $TTL \
        --region "$REGION" \
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

# ---- ASSOCIATE KB WITH AGENT ----
echo "Checking if knowledge base is already associated..."
AGENT_KBS_JSON=$(aws bedrock-agent list-agent-knowledge-bases --agent-id "$AGENT_ID" --region "$REGION" --output json 2>/dev/null || echo '{"agentKnowledgeBases":[]}')
KB_ASSOCIATED=$(echo "$AGENT_KBS_JSON" | jq -r --arg KBID "$KB_ID" '(.agentKnowledgeBases // [])[] | select(.knowledgeBaseId == $KBID) | .knowledgeBaseId')

if [ -z "$KB_ASSOCIATED" ]; then
    echo "Associating knowledge base with agent..."
    aws bedrock-agent associate-agent-knowledge-base \
        --agent-id "$AGENT_ID" \
        --knowledge-base-id "$KB_ID" \
        --region "$REGION"
    echo "Associated knowledge base: $KB_ID"
else
    echo "Knowledge base already associated with agent."
fi

# ---- AGENT VERSION MANAGEMENT ----
echo "Checking for existing agent versions..."
VERSIONS_JSON=$(aws bedrock-agent list-agent-versions --agent-id "$AGENT_ID" --region "$REGION" --output json 2>/dev/null || echo '{"agentVersions":[]}')
LATEST_VERSION=$(echo "$VERSIONS_JSON" | jq -r '.agentVersions | sort_by(.creationDateTime) | last | .agentVersion')

if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then
    echo "No existing version found. Preparing new version..."
    PREPARE_RESPONSE=$(aws bedrock-agent prepare-agent --agent-id "$AGENT_ID" --region "$REGION" --output json 2>/dev/null)
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

# ---- AGENT ALIAS MANAGEMENT ----
echo "Checking for existing 'LATEST' alias..."
ALIASES_JSON=$(aws bedrock-agent list-agent-aliases --agent-id "$AGENT_ID" --region "$REGION" --output json 2>/dev/null || echo '{"agentAliases":[]}')
EXISTING_ALIAS=$(echo "$ALIASES_JSON" | jq -r '.agentAliases[]? | select(.agentAliasName == "LATEST") | .agentAliasId')

if [ -z "$EXISTING_ALIAS" ] || [ "$EXISTING_ALIAS" = "null" ]; then
    echo "Creating new 'LATEST' alias..."
    ALIAS_CREATE_RESPONSE=$(aws bedrock-agent create-agent-alias \
        --agent-id "$AGENT_ID" \
        --agent-alias-name "LATEST" \
        --routing-configuration agentVersion="$AGENT_VERSION" \
        --region "$REGION" \
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
        --routing-configuration agentVersion="$AGENT_VERSION" \
        --region "$REGION"
    echo "Updated existing alias: $EXISTING_ALIAS"
fi

echo "Deployment completed successfully!"
echo "Agent ID: $AGENT_ID"
echo "Agent Version: $AGENT_VERSION"
echo "Knowledge Base ID: $KB_ID"