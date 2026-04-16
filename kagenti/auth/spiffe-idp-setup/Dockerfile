# Use minimal Python base image
FROM python:3.14-slim@sha256:bc389f7dfcb21413e72a28f491985326994795e34d2b86c8ae2f417b4e7818aa

# Set work directory
WORKDIR /app

# Install dependencies from requirements.txt
COPY auth/spiffe-idp-setup/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the script
COPY auth/spiffe-idp-setup/setup_spiffe_idp.py .

# Create non-root user for runtime security
RUN useradd -u 1001 -m appuser && \
    chown -R appuser:appuser /app

# Switch to non-root user
USER 1001

# Run the setup script
CMD ["python3", "setup_spiffe_idp.py"]
