# Dockerfile for SPIFFE Identity Provider Setup Job
FROM python:3.12-slim

WORKDIR /app

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the setup script
COPY setup_spiffe_idp.py .

# Make script executable
RUN chmod +x setup_spiffe_idp.py

# Create non-root user and switch to it
RUN useradd -r -u 1000 -s /bin/false appuser && \
    chown -R appuser:appuser /app
USER appuser

# Run the setup script
CMD ["python3", "setup_spiffe_idp.py"]
