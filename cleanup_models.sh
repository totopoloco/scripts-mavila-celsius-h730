#!/bin/bash
# cleanup_models.sh
# Removes all models except those in the keep list
# Modify the KEEP array to match your needs

# Models to keep (modify this list)
KEEP=("llama3.2:latest" "nomic-embed-text:latest")

# Get all installed models
ALL_MODELS=$(ollama list | tail -n +2 | awk '{print $1}')

for model in $ALL_MODELS; do
    # Check if model is in keep list
    keep=false
    for keeper in "${KEEP[@]}"; do
        if [ "$model" == "$keeper" ]; then
            keep=true
            break
        fi
    done

    # Remove if not in keep list
    if [ "$keep" = false ]; then
        echo "Removing: $model"
        ollama rm "$model"
    else
        echo "Keeping: $model"
    fi
done
