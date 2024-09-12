#!/bin/bash

domain=$1

# Function to perform geolocation lookup using ipinfo.io
function geo_lookup() {
    ip=$1
    # Get geolocation information from ipinfo.io (you can switch this to another service if preferred)
    curl -s https://ipinfo.io/$ip/json | grep -E '"ip"|"country"|"region"|"city"|"org"'
}

echo "Domain Information for: $domain"
echo "----------------------------------"

# Registrar info
echo -e "\nRegistrar Information:"
whois $domain | grep -E 'Registrar|Created|Expiration'

# Name Servers
echo -e "\nName Servers:"
dig NS $domain +short

# Mail Servers (MX Records)
echo -e "\nMail Servers (MX Records):"
dig MX $domain +short

# Hosting Server (A Record)
echo -e "\nA Record (IPv4):"
ipv4=$(dig A $domain +short)
if [ -z "$ipv4" ]; then
    echo "No IPv4 address found."
else
    echo "$ipv4"
    echo -e "\nGeolocation for A Record (IPv4):"
    geo_lookup $ipv4
fi

# Hosting Server (AAAA Record)
echo -e "\nAAAA Record (IPv6):"
ipv6=$(dig AAAA $domain +short)
if [ -z "$ipv6" ]; then
    echo "No IPv6 address found."
else
    echo "$ipv6"
    echo -e "\nGeolocation for AAAA Record (IPv6):"
    geo_lookup $ipv6
fi

# SOA Record (Start of Authority)
echo -e "\nSOA Record:"
dig SOA $domain +short

# TXT Records (SPF, DKIM, etc.)
echo -e "\nTXT Records (SPF, DKIM, etc.):"
dig TXT $domain +short

echo -e "\nReport Complete for: $domain"
