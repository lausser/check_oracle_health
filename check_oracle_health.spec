%define debug_package %{nil}

Summary:	Nagios plugins to check the status of Oracle Servers
Name:		check_oracle_health
Version:	1.7.0
Release:	1%{?dist}
License:	GPLv2+
Group:		Applications/System
URL:		http://labs.consol.de/lang/en/nagios/check_oracle_health/
Source0:	http://labs.consol.de/download/shinken-nagios-plugins/check_oracle_health-%{version}.tar.gz
Requires:	perl-Nagios-Plugin
Requires:	perl-DBD-Sybase
BuildRequires:	automake
BuildRoot:	%{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)


%description
check_oracle_health is a plugin, which is used to monitor different parameters of an Oracle database.

%prep
%setup -T -b0 

%build
aclocal
autoconf
automake
./configure --libexecdir=%{_libdir}/nagios/plugins/ --libdir=%{_libdir}
make 


%install
make install DESTDIR="%{buildroot}"

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
%doc README COPYING
%{_libdir}/nagios/plugins/check_oracle_health

%changelog

* Thu Aug 12 2012 Pall Sigurdsson <palli@opensource.is> 1.7.0
- Initial packaging
