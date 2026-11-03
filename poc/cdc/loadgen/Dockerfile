FROM python:3.12-slim
RUN pip install --no-cache-dir "psycopg[binary]==3.2.*"
COPY loadgen.py /loadgen.py
ENTRYPOINT ["python", "-u", "/loadgen.py"]
