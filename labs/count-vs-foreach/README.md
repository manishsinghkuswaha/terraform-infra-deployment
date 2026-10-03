# Lab: count, for_each, and workspaces

This uses Terraform's built-in terraform_data and creates no AWS resources.

    cd labs/count-vs-foreach
    terraform init
    terraform plan
    terraform apply
    terraform output

Expected: optional_value is Created by count; student_values contains learner_a and learner_b; workspace_name is default.

Try terraform plan -var=optional_copy_count=0. The optional object disappears. Change a map value and inspect the plan. for_each addresses objects by stable key (student_demo["learner_a"]); count uses numeric indexes, which can shift if a list is reordered.

Try terraform workspace new classroom and terraform output. The name becomes classroom. Workspaces separate state instances for one configuration; they do not automatically change access controls, variables, or provider settings. This project uses separate roots and backend keys for dev/prod. Return to default, delete classroom, then terraform destroy.
