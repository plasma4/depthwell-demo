# 1. run build
# 2. move local main bookmark to point at the working change
# 3. push changes remotely to Git
./build.sh && jj b m main && jj git push