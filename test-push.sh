docker run -d -p 5000:5000 --name registry registry:2
sleep 2
docker build -t localhost:5000/test-image:latest - <<'DOCKERFILE'
FROM alpine:latest
RUN echo "test"
DOCKERFILE
docker push localhost:5000/test-image:latest
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' localhost:5000/test-image:latest | cut -d'@' -f2)
echo "DIGEST is $DIGEST"
docker rm -f registry
