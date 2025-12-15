#!/bin/bash

# --- 1. ФУНКЦИИ И КОНФИГУРАЦИЯ ---

# Функция для проверки IP-адреса
validate_ip() {
    local ip=$1
    local stat=1
    
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# --- 2. YAML-КОД ПЛЕЙБУКА ---

cat > install.yml << EOF_YAML
---
- name: Install 3x-ui and/or XRAY
  hosts: all
  become: true
  gather_facts: false

  vars:
    install_3xui: false        
    install_xray: false        


    customize_port: "{{ 'y' if xui_port is defined else 'n' }}"
    panel_port: "{{ xui_port | default('') }}"

    xray_install_dir: "/usr/local/bin"
    xray_config_dir: "/etc/xray"
    xray_config_file: "config.json"

  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes

    - name: Upgrade system packages
      apt:
        upgrade: dist

    - name: Install common packages
      apt:
        name:
          - curl
          - wget
          - unzip
        state: present


    - name: Download 3x-ui install script
      get_url:
        url: https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh
        dest: /tmp/install-3x-ui.sh
        mode: '0755'
      when: install_3xui

    - name: Install 3x-ui
      shell: |
        echo -e "{{ customize_port }}{% if customize_port == 'y' %}\n{{ panel_port }}{% endif %}" | bash /tmp/install-3x-ui.sh
      args:
        executable: /bin/bash
      register: install_output
      when: install_3xui

    - name: Remove ANSI color codes from 3x-ui output
      set_fact:
        clean_output: "{{ install_output.stdout | replace('\x1b', '') | replace('\033', '') }}"
      when: install_3xui

    - name: Extract 3x-ui credentials
      set_fact:
        # ИСПРАВЛЕНО: Четыре слэша для корректного парсинга в Bash/YAML.
        xui_username: "{{ clean_output | regex_search('Username: ([^\\\\s]+)', '\\\\1') | default('UNKNOWN') }}"
        xui_password: "{{ clean_output | regex_search('Password: ([^\\\\s]+)', '\\\\1') | default('UNKNOWN') }}"
        xui_port_result: "{{ clean_output | regex_search('Port: ([0-9]+)', '\\\\1') | default('UNKNOWN') }}"
        xui_web_path: "{{ clean_output | regex_search('WebBasePath: ([^\\\\s]+)', '\\\\1') | default('/') }}"
        xui_access_url: "{{ clean_output | regex_search('Access URL: ([^\\\\s]+)', '\\\\1') | default('UNKNOWN') }}"
      when: install_3xui

    # НОВАЯ ЗАДАЧА: Сохранить переменные для последующего извлечения через файл
    - name: Save 3x-ui facts to a local file
      copy:
        content: |
          {
            "username": "{{ xui_username }}",
            "password": "{{ xui_password }}",
            "port": "{{ xui_port_result }}",
            "web_path": "{{ xui_web_path }}",
            "access_url": "{{ xui_access_url }}"
          }
        dest: /tmp/ansible_3xui_facts.json
      delegate_to: localhost
      run_once: true
      when: install_3xui


    - name: Create XRAY configuration directory
      file:
        path: "{{ xray_config_dir }}"
        state: directory
        mode: "0755"
      when: install_xray

    - name: Install XRAY using official script
      shell: |
        curl -L https://raw.githubusercontent.com/XTLS/Xray-install/master/install-release.sh | bash -s -- install
      args:
        creates: "{{ xray_install_dir }}/xray"
      when: install_xray

    - name: Verify XRAY binary exists
      stat:
        path: "{{ xray_install_dir }}/xray"
      register: xray_bin
      when: install_xray

    - name: Fail if XRAY installation failed
      fail:
        msg: "XRAY installation failed!"
      when:
        - install_xray
        - not xray_bin.stat.exists

    - name: Create XRAY config file
      copy:
        dest: "{{ xray_config_dir }}/{{ xray_config_file }}"
        mode: '0644'
        content: |
          {
            "inbounds": [
              {
                "port": 1080,
                "protocol": "socks",
                "settings": {
                  "auth": "noauth",
                  "udp": true
                }
              }
            ],
            "outbounds": [
              {
                "protocol": "freedom",
                "settings": {}
              }
            ]
          }
      when: install_xray

    - name: Create XRAY systemd service
      copy:
        dest: /etc/systemd/system/xray.service
        mode: '0644'
        content: |
          [Unit]
          Description=XRAY Service
          After=network.target

          [Service]
          ExecStart={{ xray_install_dir }}/xray -config {{ xray_config_dir }}/{{ xray_config_file }}
          Restart=on-failure

          [Install]
          WantedBy=multi-user.target
      when: install_xray

    - name: Reload systemd
      systemd:
        daemon_reload: yes
      when: install_xray

    - name: Enable and start XRAY
      systemd:
        name: xray
        enabled: yes
        state: started
      when: install_xray
EOF_YAML

# --- 3. УСТАНОВКА ЗАВИСИМОСТЕЙ И ЗАПУСК ---

echo "=== Создание файла hosts.ini для Ansible ==="
echo ""

# Запрашиваем IP-адрес с проверкой
while true; do
    read -p "Введите IP-адрес VPS: " vps_ip
    
    if validate_ip "$vps_ip"; then
        break
    else
        echo "❌ Неверный формат IP-адреса. Попробуйте снова."
    fi
done

# Запрашиваем пароль
while true; do
    read -sp "Введите пароль root пользователя: " vps_password1
    echo ""
    
    if [ -z "$vps_password1" ]; then
        echo "❌ Пароль не может быть пустым."
        continue
    fi
    
    read -sp "Повторите пароль: " vps_password2
    echo ""
    
    if [ "$vps_password1" != "$vps_password2" ]; then
        echo "❌ Пароли не совпадают. Попробуйте снова."
    else
        vps_password="$vps_password1"
        break
    fi
done

# Создаем файлы конфигурации
# НОВОЕ: Создаем ansible.cfg для отключения проверки ключей
cat > ansible.cfg << EOF_CFG
[defaults]
host_key_checking = False
EOF_CFG

# Создаем файл hosts.ini
cat > hosts.ini << EOF
# Ansible inventory file
[vps]
$vps_ip ansible_user=root ansible_ssh_pass=$vps_password
EOF

# Проверка и установка коллекции UFW (community.general)
echo "=== Проверка и установка необходимых коллекций Ansible ==="
if ! ansible-galaxy collection list | grep -q 'community.general' ; then
    echo "⚠️ Коллекция community.general (для UFW) не найдена. Установка..."
    sudo ansible-galaxy collection install community.general
    if [ $? -ne 0 ]; then
        echo "🛑 ОШИБКА: Не удалось установить коллекцию community.general. Проверьте права и подключение."
        exit 1
    fi
    echo "✅ Коллекция community.general установлена."
fi

# СЕКЦИЯ: Автоматическая очистка старого SSH-ключа хоста (все еще нужна, если вы ВДРУГ запустите без ansible.cfg)
echo ""
echo ""
if sudo ssh-keygen -f "/root/.ssh/known_hosts" -R "$vps_ip" > /dev/null 2>&1; then
    echo ""
else
    echo ""
fi


echo ""
echo "=== Запуск Ansible Playbook ==="
echo ""

# ПРАВИЛЬНЫЙ ЗАПУСК И ЗАХВАТ СТАТУСА
ansible-playbook -i hosts.ini install.yml \
  --extra-vars "install_3xui=true xui_port=2053 install_xray=true"

playbook_status=$?

# --- 4. ФИНАЛЬНЫЙ ВЫВОД И ОЧИСТКА ---

# Используем двойные кавычки для безопасности в Bash
if [ "$playbook_status" -eq 0 ]; then
    echo ""
    echo "========================================================"
    echo "✅ Установка 3x-ui завершена. Учетные данные:"
    echo "========================================================"
    
    # Извлечение данных из локального файла, созданного в плейбуке
    FACT_FILE="/tmp/ansible_3xui_facts.json"
    
    # Проверка наличия jq для парсинга JSON
    if ! command -v jq &> /dev/null; then
        echo "⚠️ Утилита 'jq' не найдена. Невозможно красиво извлечь учетные данные."
        echo "   (Установите 'jq', чтобы видеть форматированный вывод)."
        cat "$FACT_FILE" 2>/dev/null
    elif [ -f "$FACT_FILE" ]; then
        # Чтение JSON и вывод
        USERNAME=$(jq -r '.username' "$FACT_FILE")
        PASSWORD=$(jq -r '.password' "$FACT_FILE")
        PORT=$(jq -r '.port' "$FACT_FILE")
        WEB_PATH=$(jq -r '.web_path' "$FACT_FILE")
        ACCESS_URL=$(jq -r '.access_url' "$FACT_FILE")

        echo "🔑 Имя пользователя: $USERNAME"
        echo "🔒 Пароль: $PASSWORD"
        echo "🚪 Порт панели: $PORT"
        echo "🌐 WebBasePath: $WEB_PATH"
        echo "🔗 Ссылка для доступа: $ACCESS_URL"
        
        # Очистка временного файла фактов
        rm -f "$FACT_FILE"
    else
        echo "⚠️ Файл учетных данных не найден. Возможно, 3x-ui не был установлен."
    fi

else
    echo ""
    echo "========================================================"
    echo "❌ Ansible Playbook завершился с ошибкой."
    echo "========================================================"
fi


# ОЧИСТКА ФАЙЛОВ
echo ""
echo "=== Очистка файлов hosts.ini, install.yml и ansible.cfg ==="
rm -f hosts.ini install.yml ansible.cfg
echo "✅ hosts.ini, install.yml и ansible.cfg удалены."