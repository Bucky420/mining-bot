while true do
    local ok = shell.run("deploy_server")
    if ok then return end
    printError("Deployment server stopped; retrying in 5 seconds.")
    sleep(5)
end
