function git_update
    if git remote get-url origin | grep 'p-720';
        echo "commiting";
        git add .;
        git commit -m "update $(date "+%H:%M %a, %d %b")";
        git push origin;
    end
end
