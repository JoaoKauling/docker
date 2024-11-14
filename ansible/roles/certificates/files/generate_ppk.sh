#!/bin/bash

# Função para exibir o uso do script
display_usage() {
    echo "Usage: $0 <hosts_file>"
    echo
    echo "Parameters:"
    echo "  <hosts_file>     : A file containing the list of remote hosts and their IP addresses."
    echo
    echo "The hosts_file should contain one line per host, formatted as follows:"
    echo "  <IP address> <hostname>"
    echo
    echo "Example:"
    echo "  192.168.1.10 server1"
    echo "  192.168.1.11 server2"
    echo
    echo "This file will be used to send the generated SSH key to each remote host and update /etc/hosts."
}

# Função para gerar e configurar a chave SSH
generate_ssh_key() {
    key_file="/home/$remote_user/.ssh/id_rsa"
    pub_key_file="$key_file.pub"
    if [ ! -f "$pub_key_file" ]; then
        echo "Generating SSH key..."
        ssh-keygen -t rsa -N '' -f "$key_file" <<< y >/dev/null 2>&1
    fi

    auth_keys_file="/home/$remote_user/.ssh/authorized_keys"
    if [ ! -f "$auth_keys_file" ]; then
        echo "Creating $auth_keys_file..."
        touch "$auth_keys_file"
        chmod 600 "$auth_keys_file"
    fi

    if ! grep -Fq "$(cat $pub_key_file)" "$auth_keys_file"; then
        echo "Adding SSH key to $auth_keys_file..."
        cat $pub_key_file >> "$auth_keys_file"
    fi
}

# Função para atualizar /etc/hosts
update_hosts_file() {
    echo "Updating /etc/hosts with entries from $hosts_file..."
    sudo cp /etc/hosts /etc/hosts.bak
    echo "Processing hosts file entries..."
    while IFS= read -r remote_server; do
        echo "Read line: $remote_server"
        ip=$(echo "$remote_server" | awk '{print $1}')
        host=$(echo "$remote_server" | awk '{print $2}')

        echo "Processing entry: $ip $host"

        if ! grep -q "$ip\s\+$host" /etc/hosts; then
            echo "$ip $host" | sudo tee -a /etc/hosts >/dev/null
            echo "Added $ip $host to /etc/hosts."
        else
            echo "$ip $host already exists in /etc/hosts."
        fi
    done < "$hosts_file"
}

# Function to send and verify SSH keys
send_and_verify_key() {
    local ip="$1"
    local host="$2"

    echo ""
    echo "Sending SSH key to $host ($ip)..."

    # Debugging output to ensure we're reading the correct data
    echo "Attempting to send SSH key to $remote_user@$host..."

    if sshpass -p "$remote_password" ssh-copy-id -i "$pub_key_file" -o StrictHostKeyChecking=no "$remote_user@$host"; then
        echo "SSH key successfully added to $host."
    else
        echo "Failed to send SSH key to $host."
        return
    fi
}


# Função principal
main() {
    # Verificar se o número correto de parâmetros foi fornecido
    if [ $# -ne 1 ]; then
        display_usage
        exit 1
    fi

    hosts_file=$1
    local_username="root"

    # Solicitar o nome de usuário remoto
    read -p "Enter the remote username (press Enter to use root): " remote_username
    remote_user=${remote_username:-$local_username}

    # Solicitar a senha do usuário remoto
    echo "Enter the password for the remote user $remote_user:"
    read -s remote_password

    # Confirmar a senha do usuário remoto
    echo "Confirm the password for the remote user $remote_user:"
    read -s remote_password_confirm

    # Verificar se as senhas conferem
    if [ "$remote_password" != "$remote_password_confirm" ]; then
        echo "Passwords do not match. Please try again."
        exit 1
    fi

    # Gerar e configurar a chave SSH
    generate_ssh_key

    # Atualizar o arquivo /etc/hosts
    update_hosts_file

    # Enviar e verificar chaves SSH nos hosts remotos
    echo "Sending SSH keys to remote hosts..."
    while IFS= read -r remote_server; do
        echo "--------------------------------"
        echo "Read line: $remote_server"
        ip=$(echo "$remote_server" | awk '{print $1}')
        host=$(echo "$remote_server" | awk '{print $2}')
        send_and_verify_key "$host" "$ip"
        echo "--------------------------------"
    done < "$hosts_file"

}

# Executar função principal
main "$@"
