# SYNTHETIC LMS test application image. Built and run only on a development
# machine or CI runner; nothing here is installed on a monitored VM.
FROM eclipse-temurin:11-jdk

# PostgreSQL JDBC driver from Maven Central, pinned by version and SHA-256.
ARG PGJDBC_VERSION=42.7.4
ARG PGJDBC_SHA256=188976721ead8e8627eb6d8389d500dccc0c9bebd885268a3047180274a6031e
ADD https://repo1.maven.org/maven2/org/postgresql/postgresql/${PGJDBC_VERSION}/postgresql-${PGJDBC_VERSION}.jar /app/postgresql.jar
RUN echo "${PGJDBC_SHA256}  /app/postgresql.jar" | sha256sum -c -

COPY LmsApp.java entrypoint.sh /app/
RUN mkdir -p /app/classes && javac -cp /app/postgresql.jar -d /app/classes /app/LmsApp.java

EXPOSE 8080
ENTRYPOINT ["sh", "/app/entrypoint.sh"]
