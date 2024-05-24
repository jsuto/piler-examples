<?php

$settings = [
   'security' => [
      'allowRepeatAttributeName' => true,
      'authnRequestsSigned' => true,
      'logoutRequestSigned' => true,
      'logoutResponseSigned' => true,
      'wantMessagesSigned' => true,
   ],

   'sp' => [
      'entityId' => 'piler-saml',
      'NameIDFormat' => 'urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress',
      'assertionConsumerService' => [
            'url' => 'https://archive.example.com/callback-saml2',
      ],
      'singleLogoutService' => [
        'url' => 'https://archive.example.com/logout',
      ],
      'x509cert' => '-----BEGIN CERTIFICATE-----MIIFlT....pgwxA=-----END CERTIFICATE-----',
      'privateKey' => '-----BEGIN PRIVATE KEY-----MIIJQg...X4Lb18ZgPQ==-----END PRIVATE KEY-----',
   ],

   'idp' => [
      'entityId' => 'https://keycloak.example.com/realms/example-realm',
      'singleSignOnService' => [
         'url' => 'https://keycloak.example.com/realms/example-realm/protocol/saml',
      ],
      'singleLogoutService' => [
            'url' => 'https://keycloak.example.com/realms/example-realm/protocol/saml',
      ],
      'x509cert' => '-----BEGIN CERTIFICATE-----MIICpTCC.....OEdfBU-----END CERTIFICATE-----',
   ],
];
