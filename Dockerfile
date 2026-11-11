# 1. Start from an official image that already has Python installed
FROM python:3.12-slim

# 2. All following commands run inside /app in the container
WORKDIR /app

# 3. Copy ONLY the dependency list first, then install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 4. Now copy the rest of your code
COPY . .

# 5. Document the port the app listens on
EXPOSE 8000

# 6. The command that runs when the container starts
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]