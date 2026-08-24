while true do
    local ok = shell.run("relay")
    if ok then return end
    printError("Deployment relay stopped; retrying in 5 seconds.")
    sleep(5)
end
