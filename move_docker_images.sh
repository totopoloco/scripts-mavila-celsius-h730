#!/bin/bash

# Function to save images to tar files
save_images() {
    echo "Switching to default context..."
    docker context use default

    echo "Saving Docker images to tar files..."
    for image in $(docker images -q); do
        image_name=$(docker inspect --format='{{.RepoTags}}' $image | sed 's/[][]//g')
        sanitized_image_name=$(echo $image_name | tr '/' '_' | tr ':' '_')
        docker save "${image_name}" | gzip > "${sanitized_image_name}.tar.gz"
        echo "Saved $image_name to ${sanitized_image_name}.tar.gz"
        echo "----"
    done
}

# Function to load images from tar files
load_images() {
    echo "Switching to desktop-linux context..."
    docker context use desktop-linux

    echo "Loading Docker images from tar files..."
    for file in *tar.gz; do
        docker load --input $file
        echo "Loaded image from $file"
    done
}

return_to_context() {
    docker context use default
}

delete_tars() {
  echo "Deleting tars"
  find . -name "*tar.gz" -type f -exec rm {} \; -print
}

# Main script execution
save_images
load_images
delete_tars
return_to_context

echo "All images have been moved from default context to desktop-linux context."
