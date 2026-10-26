# The official Dart server pattern: AOT-compile, then copy the executable
# and the Dart runtime files (including CA certificates) into scratch.
FROM dart:3.12.0 AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart compile exe bin/server.dart -o bin/server

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/bin/server /app/bin/server
EXPOSE 8080
CMD ["/app/bin/server"]
